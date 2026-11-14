import AVFoundation
import Network
import UIKit

private enum MessageType: UInt8 {
    case config = 1
    case videoFrame = 2
    case touch = 3
    case audioConfig = 4
    case audioFrame = 5
}

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = DisplayViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class DisplayViewController: UIViewController {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let statusLabel = UILabel()
    private let statusContainer = UIView()
    private let touchView = TouchView()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var formatDescription: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0
    private var renderedFrames = 0

    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var audioRunning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        displayLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(displayLayer)

        statusLabel.text = "等待 Mac 连接…\n(listening :12346)"
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont(name: "Menlo", size: 17)
        statusLabel.layer.shadowColor = UIColor.black.cgColor
        statusLabel.layer.shadowOpacity = 0.9
        statusLabel.layer.shadowRadius = 4
        statusLabel.layer.shadowOffset = .zero
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusContainer.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        statusContainer.layer.cornerRadius = 14
        statusContainer.layer.borderWidth = 1
        statusContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusLabel)
        view.addSubview(statusContainer)

        touchView.translatesAutoresizingMaskIntoConstraints = false
        touchView.onTouch = { [weak self] phase, point in
            self?.sendTouch(phase: phase, point: point)
        }
        view.addSubview(touchView)

        NSLayoutConstraint.activate([
            statusContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -20),
            touchView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            touchView.topAnchor.constraint(equalTo: view.topAnchor),
            touchView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        UIApplication.shared.isIdleTimerDisabled = true
        startListener()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = view.bounds
        CATransaction.commit()
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: 12346),
              let listener = try? NWListener(using: params, on: port) else {
            setStatus("监听失败")
            return
        }
        listener.service = NWListener.Service(name: UIDevice.current.name, type: "_ipaddisplay._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.setStatus("等待 Mac 连接…\n已广播 _ipaddisplay._tcp · :12346")
                case .waiting(let error), .failed(let error):
                    self?.setStatus("监听异常: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        readBuffer.removeAll()
        formatDescription = nil
        frameIndex = 0
        stopAudio()
        displayLayer.flushAndRemoveImage()

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.setStatus("已连接，等待画面…")
                case .failed, .cancelled:
                    self?.setStatus("连接已断开，等待 Mac 重连…")
                default:
                    break
                }
            }
        }
        connection.start(queue: .global())
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                self.drainBuffer()
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func drainBuffer() {
        while readBuffer.count >= 8 {
            let header = [UInt8](readBuffer.prefix(8))
            let length = UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                | UInt32(header[2]) << 8 | UInt32(header[3])
            let type = header[4]
            guard length > 0, length <= 16 * 1024 * 1024 else {
                readBuffer.removeAll()
                connection?.cancel()
                setStatus("协议错误：帧长度 \(length)")
                return
            }
            guard readBuffer.count >= 8 + Int(length) else { return }
            let payload = Data(readBuffer.dropFirst(8).prefix(Int(length)))
            readBuffer.removeFirst(8 + Int(length))
            handle(type: type, payload: payload)
        }
    }

    private func handle(type: UInt8, payload: Data) {
        switch MessageType(rawValue: type) {
        case .config:
            configure(with: payload)
        case .videoFrame:
            enqueueFrame(payload)
        case .audioConfig:
            configureAudio(with: payload)
        case .audioFrame:
            enqueueAudio(payload)
        default:
            break
        }
    }

    private func configureAudio(with payload: Data) {
        guard payload.count >= 8 else { return }
        let bytes = [UInt8](payload)
        let sampleRate = Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                               | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        let channels = UInt32(bytes[4]) << 8 | UInt32(bytes[5])
        let bits = UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        guard sampleRate >= 8000, channels > 0, channels <= 8, bits == 16 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.startAudio(sampleRate: sampleRate, channels: channels)
        }
    }

    private func startAudio(sampleRate: Double, channels: UInt32) {
        stopAudio()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: true) else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        audioEngine.attach(audioPlayer)
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        guard (try? audioEngine.start()) != nil else {
            audioEngine.detach(audioPlayer)
            return
        }
        audioPlayer.play()
        audioFormat = format
        audioRunning = true
    }

    private func stopAudio() {
        guard audioRunning || audioFormat != nil else { return }
        audioRunning = false
        audioFormat = nil
        audioPlayer.stop()
        audioEngine.stop()
        audioEngine.disconnectNodeOutput(audioPlayer)
        audioEngine.detach(audioPlayer)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func enqueueAudio(_ payload: Data) {
        guard audioRunning, let format = audioFormat else { return }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frames = payload.count / bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let target = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(target, base, frames * bytesPerFrame)
        }
        audioPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func configure(with payload: Data) {
        guard payload.count >= 8 else { return }
        let bytes = [UInt8](payload)
        let width = Int(bytes[0]) << 8 | Int(bytes[1])
        let height = Int(bytes[2]) << 8 | Int(bytes[3])
        var offset = 4
        guard let sps = readBlock(bytes, offset: &offset),
              let pps = readBlock(bytes, offset: &offset) else { return }

        var format: CMFormatDescription?
        sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                let pointers: [UnsafePointer<UInt8>] = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        formatDescription = format
        DispatchQueue.main.async {
            self.setStatus("\(width)×\(height) 已就绪")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showStatus(nil)
            }
        }
    }

    private func readBlock(_ bytes: [UInt8], offset: inout Int) -> [UInt8]? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        offset += 4
        guard length > 0, offset + length <= bytes.count else { return nil }
        let block = Array(bytes[offset..<(offset + length)])
        offset += length
        return block
    }

    private func enqueueFrame(_ payload: Data) {
        guard let formatDescription else { return }
        if #available(iOS 14.0, *), displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flushAndRemoveImage()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }

        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )
        frameIndex += 1

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        displayLayer.enqueue(sampleBuffer)
        renderedFrames += 1
        if renderedFrames <= 90, renderedFrames % 30 == 0 {
            let count = renderedFrames
            DispatchQueue.main.async {
                self.showStatus("已连接 · \(count) 帧")
            }
        } else if renderedFrames == 91 {
            DispatchQueue.main.async {
                self.showStatus(nil)
            }
        }
    }

    private func sendTouch(phase: UInt8, point: CGPoint) {
        guard let connection else { return }
        let x = Float(point.x / max(view.bounds.width, 1))
        let y = Float(point.y / max(view.bounds.height, 1))
        var payload = Data([phase])
        for value in [x, y] {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        var header = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(MessageType.touch.rawValue)
        header.append(contentsOf: [0, 0, 0])
        connection.send(content: header + payload, completion: .contentProcessed { _ in })
    }

    private func setStatus(_ text: String) {
        showStatus(text)
    }

    private func showStatus(_ text: String?) {
        statusLabel.text = text
        statusContainer.isHidden = text == nil
    }
}

final class TouchView: UIView {
    var onTouch: ((UInt8, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, phase: 0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, phase: 1)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, phase: 2)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, phase: 2)
    }

    private func emit(_ touches: Set<UITouch>, phase: UInt8) {
        guard let touch = touches.first else { return }
        onTouch?(phase, touch.location(in: self))
    }
}
