import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox

enum MessageType: UInt8 {
    case config = 1
    case videoFrame = 2
    case touch = 3
    case audioConfig = 4
    case audioFrame = 5
    case keyboard = 6
    case textInput = 7
    case scroll = 8
}

struct StreamStats {
    var fps: Double = 0
    var megabytesPerSecond: Double = 0
    var frames: Int = 0
    var touches: Int = 0
    var dropped: Int = 0
    var audioBytes: Int = 0
    var encodedWidth: Int = 0
    var encodedHeight: Int = 0
}

enum StreamEngineError: LocalizedError {
    case tunnel(String)
    case capture(String)

    var errorDescription: String? {
        switch self {
        case .tunnel(let text): return text
        case .capture(let text): return text
        }
    }
}

final class StreamEngine: NSObject {
    var onLog: ((String) -> Void)?
    var onStats: ((StreamStats) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onConnected: (() -> Void)?

    private let writeQueue = DispatchQueue(label: "ipad.display.write")
    private let captureQueue = DispatchQueue(label: "ipad.display.capture")
    private let statsQueue = DispatchQueue(label: "ipad.display.stats")
    private var tunnel: Int32 = -1
    private var captureStream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var sendConfigNext = true
    private var frameIndex: Int64 = 0
    private var readBuffer = Data()
    private var targetDisplay: SCDisplay?
    private var displayBounds: CGRect = .zero
    private var pendingFrames = 0
    private var isRunning = false
    private var droppedFrames = 0
    private var captureWidth = 0
    private var captureHeight = 0
    private var audioEnabled = false
    private var sentAudioConfig = false
    private let stateLock = NSLock()
    private var pendingWrites = 0

    private var stats = StreamStats()
    private var frameCounter = 0
    private var byteCounter = 0
    private var lastStatsAt = Date()

    private(set) var bitrate = 12_000_000
    private(set) var fps = 30

    func start(tunnelFD: Int32, display: SCDisplay, displayBounds: CGRect,
               captureSize: CGSize, audio: Bool, fps: Int, bitrate: Int) async throws {
        isRunning = true
        self.fps = fps
        self.bitrate = bitrate
        self.targetDisplay = display
        self.displayBounds = displayBounds
        audioEnabled = audio
        tunnel = tunnelFD
        onLog?("隧道已建立 (fd \(tunnelFD))")

        if audio {
            sendAudioConfiguration()
        }
        try await startCapture(display: display, size: captureSize)
        startReading()
        startStats()
    }

    func stop() {
        isRunning = false
        audioEnabled = false
        sentAudioConfig = false
        if let stream = captureStream {
            Task { try? await stream.stopCapture() }
        }
        captureStream = nil
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        sendConfigNext = true
        frameIndex = 0
        pendingFrames = 0
        if tunnel >= 0 {
            close(tunnel)
            tunnel = -1
        }
        stats = StreamStats()
        frameCounter = 0
        byteCounter = 0
    }

    private func startStats() {
        lastStatsAt = Date()
        scheduleStatsTick()
    }

    private func scheduleStatsTick() {
        statsQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isRunning else { return }
            let elapsed = Date().timeIntervalSince(self.lastStatsAt)
            if elapsed > 0 {
                self.stats.fps = Double(self.frameCounter) / elapsed
                self.stats.megabytesPerSecond = Double(self.byteCounter) / elapsed / 1_048_576
                self.stats.frames += self.frameCounter
                self.stats.dropped += self.droppedFrames
                self.droppedFrames = 0
                self.frameCounter = 0
                self.byteCounter = 0
                self.lastStatsAt = Date()
                let snapshot = self.stats
                self.onStats?(snapshot)
            }
            self.scheduleStatsTick()
        }
    }

    private func startCapture(display: SCDisplay, size: CGSize) async throws {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        captureWidth = width
        captureHeight = height

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = audioEnabled
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            if audioEnabled {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            }
            try await stream.startCapture()
        } catch {
            throw StreamEngineError.capture("屏幕采集失败：\(error.localizedDescription)。请在系统设置中允许「屏幕录制」。")
        }
        captureStream = stream
        createEncoder(width: width, height: height)
        stats.encodedWidth = width
        stats.encodedHeight = height
        onLog?("开始采集 \(width)×\(height) @\(fps)fps")
        if audioEnabled {
            onLog?("音频透传已开启（48kHz 立体声）")
        }
    }

    private func createEncoder(width: Int, height: Int) {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: streamCompressionCallback,
                                                refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                compressionSessionOut: &session)
        guard status == noErr, let session else {
            onLog?("编码器创建失败 (\(status))")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 3))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        sendConfigNext = true
        frameIndex = 0
    }

    private func startReading() {
        let fd = tunnel
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: writeQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 {
                source.cancel()
                self.handleTunnelClosed()
                return
            }
            self.readBuffer.append(contentsOf: buffer[0..<count])
            self.drainTouches()
        }
        source.resume()
        readSource = source
    }

    private var readSource: DispatchSourceRead?

    private func handleTunnelClosed() {
        guard isRunning else { return }
        isRunning = false
        onDisconnect?("iPad 连接已断开")
    }

    private func drainTouches() {
        while readBuffer.count >= 8 {
            let header = [UInt8](readBuffer.prefix(8))
            let length = UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                | UInt32(header[2]) << 8 | UInt32(header[3])
            guard length <= 4096 else {
                readBuffer.removeAll()
                return
            }
            guard readBuffer.count >= 8 + Int(length) else { return }
            let payload = [UInt8](readBuffer.dropFirst(8).prefix(Int(length)))
            readBuffer.removeFirst(8 + Int(length))
            guard let kind = MessageType(rawValue: header[4]) else { continue }
            switch kind {
            case .touch:
                handleTouchPayload(payload)
            case .scroll:
                handleScrollPayload(payload)
            case .textInput:
                handleTextPayload(payload)
            default:
                continue
            }
        }
    }

    private func handleTouchPayload(_ payload: [UInt8]) {
        guard payload.count >= 9 else { return }
        let phase = payload[0]
        let xBits = UInt32(payload[1]) << 24 | UInt32(payload[2]) << 16
            | UInt32(payload[3]) << 8 | UInt32(payload[4])
        let yBits = UInt32(payload[5]) << 24 | UInt32(payload[6]) << 16
            | UInt32(payload[7]) << 8 | UInt32(payload[8])
        var nx = Double(Float(bitPattern: xBits))
        var ny = Double(Float(bitPattern: yBits))
        guard nx.isFinite, ny.isFinite else { return }
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)
        stats.touches += 1
        injectTouch(phase: phase, x: nx, y: ny)
    }

    private func handleScrollPayload(_ payload: [UInt8]) {
        guard payload.count >= 8 else { return }
        let dxBits = UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16
            | UInt32(payload[2]) << 8 | UInt32(payload[3])
        let dyBits = UInt32(payload[4]) << 24 | UInt32(payload[5]) << 16
            | UInt32(payload[6]) << 8 | UInt32(payload[7])
        let dx = Double(Float(bitPattern: dxBits))
        let dy = Double(Float(bitPattern: dyBits))
        guard dx.isFinite, dy.isFinite else { return }
        injectScroll(dx: dx, dy: dy)
    }

    private func handleTextPayload(_ payload: [UInt8]) {
        guard let kind = payload.first else { return }
        switch kind {
        case 0:
            let text = String(decoding: payload.dropFirst(), as: UTF8.self)
            guard !text.isEmpty else { return }
            typeUnicode(text)
        case 1:
            tapKey(51)
        case 2:
            tapKey(36)
        default:
            break
        }
    }

    func setKeyboardVisible(_ visible: Bool) {
        send(.keyboard, payload: Data([visible ? 1 : 0]))
    }

    private func injectScroll(dx: Double, dy: Double) {
        guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((-dy).rounded()),
                                  wheel2: Int32(dx.rounded()),
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func typeUnicode(_ text: String) {
        let units = Array(text.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        usleep(2_000)
    }

    private func tapKey(_ keyCode: CGKeyCode) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.post(tap: .cghidEventTap)
        }
        usleep(2_000)
    }

    private func injectTouch(phase: UInt8, x: Double, y: Double) {
        let point = CGPoint(x: displayBounds.origin.x + x * displayBounds.width,
                            y: displayBounds.origin.y + y * displayBounds.height)
        if phase == 0 {
            onLog?(String(format: "触控 (%.2f, %.2f) → 屏幕 (%.0f, %.0f)",
                          x, y, point.x, point.y))
        }
        postMouse(.mouseMoved, at: point, button: .left)
        switch phase {
        case 3:
            return
        case 4:
            postMouse(.rightMouseDown, at: point, button: .right)
            postMouse(.rightMouseUp, at: point, button: .right)
            return
        case 0:
            postMouse(.leftMouseDown, at: point, button: .left)
        case 1:
            postMouse(.leftMouseDragged, at: point, button: .left)
        default:
            postMouse(.leftMouseUp, at: point, button: .left)
        }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                 mouseCursorPosition: point, mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func send(_ type: MessageType, payload: Data) {
        guard tunnel >= 0 else { return }
        stateLock.lock()
        if type == .videoFrame && pendingWrites >= 6 {
            droppedFrames += 1
            stateLock.unlock()
            return
        }
        pendingWrites += 1
        stateLock.unlock()

        var packet = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(type.rawValue)
        packet.append(contentsOf: [0, 0, 0])
        packet.append(payload)
        let fd = tunnel
        writeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.pendingWrites -= 1
                self.stateLock.unlock()
            }
            guard self.tunnel == fd else { return }
            var sent = 0
            let total = packet.count
            packet.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while sent < total {
                    let written = write(fd, base.advanced(by: sent), total - sent)
                    if written <= 0 { return }
                    sent += written
                }
            }
        }
    }

    fileprivate func handleEncoded(sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        if sendConfigNext {
            var payload = Data()
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var width = UInt16(dimensions.width).bigEndian
            var height = UInt16(dimensions.height).bigEndian
            withUnsafeBytes(of: &width) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &height) { payload.append(contentsOf: $0) }
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                                                                         parameterSetIndex: index,
                                                                         parameterSetPointerOut: &pointer,
                                                                         parameterSetSizeOut: &size,
                                                                         parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer else { return }
                var length = UInt32(size).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(pointer, count: size)
            }
            send(.config, payload: payload)
            sendConfigNext = false
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        send(.videoFrame, payload: data)
        frameCounter += 1
        byteCounter += length
    }

    private func sendAudioConfiguration() {
        var payload = Data()
        var sampleRate = UInt32(48_000).bigEndian
        var channels = UInt16(2).bigEndian
        var bits = UInt16(16).bigEndian
        withUnsafeBytes(of: &sampleRate) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &channels) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        send(.audioConfig, payload: payload)
        sentAudioConfig = true
    }

    fileprivate func handleAudio(sampleBuffer: CMSampleBuffer) {
        guard audioEnabled,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channelCount = Int(description.mChannelsPerFrame)
        guard frames > 0, channelCount > 0 else { return }

        let list = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(list.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isPlanar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard isFloat else { return }

        var output = [Int16](repeating: 0, count: frames * channelCount)
        if isPlanar {
            let sourceChannels = min(channelCount, list.count)
            guard sourceChannels > 0 else { return }
            for channel in 0..<sourceChannels {
                guard let data = list[channel].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let value = max(-1, min(1, samples[frame]))
                    output[frame * channelCount + channel] = Int16(value * 32_767)
                }
            }
        } else if let data = list[0].mData {
            let available = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<min(available, output.count) {
                let value = max(-1, min(1, samples[index]))
                output[index] = Int16(value * 32_767)
            }
        }

        if !sentAudioConfig { sendAudioConfiguration() }
        let payload = output.withUnsafeBufferPointer { Data(buffer: $0) }
        send(.audioFrame, payload: payload)

        stateLock.lock()
        stats.audioBytes += payload.count
        stateLock.unlock()
    }
}

extension StreamEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            handleAudio(sampleBuffer: sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession else { return }
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        frameIndex += 1
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: nil)
    }
}

private func streamCompressionCallback(refcon: UnsafeMutableRawPointer?,
                                       sourceFrameRefcon: UnsafeMutableRawPointer?,
                                       status: OSStatus,
                                       infoFlags: VTEncodeInfoFlags,
                                       sampleBuffer: CMSampleBuffer?) {
    guard status == noErr, let sampleBuffer, let refcon else { return }
    let engine = Unmanaged<StreamEngine>.fromOpaque(refcon).takeUnretainedValue()
    engine.handleEncoded(sampleBuffer: sampleBuffer)
}
