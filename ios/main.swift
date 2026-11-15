import AVFoundation
import MediaPlayer
import Network
import UIKit

private enum MessageType: UInt8 {
    case config = 1
    case videoFrame = 2
    case touch = 3
    case audioConfig = 4
    case audioFrame = 5
    case keyboard = 6
    case textInput = 7
    case scroll = 8
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
    private let controlBar = UIStackView()
    private let modeButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let linkButton = UIButton(type: .system)
    private let keyboardCatcher = KeyboardCatcher()
    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    private var listener: NWListener?
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var formatDescription: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0
    private var renderedFrames = 0
    private var listening = false
    private var controlsVisible = true
    private var suppressGesture = false
    private var fadeWork: DispatchWorkItem?
    private var scrollMode = UserDefaults.standard.bool(forKey: "ipadScrollMode")
    private let audioStateLock = NSLock()
    private var audioMuted = UserDefaults.standard.bool(forKey: "ipadAudioMuted")

    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "ipaddisplay.audio")
    private var audioFormat: AVAudioFormat?
    private var audioRunning = false
    private var audioAttached = false
    private var queuedAudioFrames = 0

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
        touchView.isScrollMode = scrollMode
        touchView.onTouch = { [weak self] phase, point in
            guard let self else { return }
            if phase == 0 {
                if !self.controlsVisible {
                    self.suppressGesture = true
                    self.showControls()
                    return
                }
                self.suppressGesture = false
            }
            guard !self.suppressGesture else { return }
            self.sendTouch(phase: phase, point: point)
        }
        touchView.onMove = { [weak self] point in
            self?.sendTouch(phase: 3, point: point)
        }
        touchView.onClick = { [weak self] point in
            self?.sendTouch(phase: 0, point: point)
            self?.sendTouch(phase: 2, point: point)
        }
        touchView.onRightClick = { [weak self] point in
            self?.sendTouch(phase: 4, point: point)
        }
        touchView.onScroll = { [weak self] dx, dy in
            self?.sendScroll(dx: dx, dy: dy)
        }
        view.addSubview(touchView)

        configureControl(modeButton, action: #selector(toggleMode))
        configureControl(audioButton, action: #selector(toggleAudio))
        configureControl(linkButton, action: #selector(toggleLink))

        controlBar.axis = .horizontal
        controlBar.spacing = 10
        controlBar.alignment = .fill
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addArrangedSubview(modeButton)
        controlBar.addArrangedSubview(audioButton)
        controlBar.addArrangedSubview(linkButton)
        view.addSubview(controlBar)

        keyboardCatcher.alpha = 0.02
        keyboardCatcher.isUserInteractionEnabled = false
        keyboardCatcher.onInsert = { [weak self] text in self?.sendInsert(text) }
        keyboardCatcher.onDelete = { [weak self] in self?.sendMessage(.textInput, payload: Data([1])) }
        keyboardCatcher.onReturn = { [weak self] in self?.sendMessage(.textInput, payload: Data([2])) }
        keyboardCatcher.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardCatcher)

        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)
        updateModeButton()
        updateAudioButton()
        updateLinkButton()

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
            touchView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            controlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            volumeView.widthAnchor.constraint(equalToConstant: 1),
            volumeView.heightAnchor.constraint(equalToConstant: 1),
            volumeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            volumeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardCatcher.widthAnchor.constraint(equalToConstant: 1),
            keyboardCatcher.heightAnchor.constraint(equalToConstant: 1),
            keyboardCatcher.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardCatcher.topAnchor.constraint(equalTo: view.topAnchor)
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
                    self?.setStatus("等待 Mac 连接…\n已广播 Bonjour · :12346")
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
        listening = true
        updateLinkButton()
    }

    private func stopListener() {
        listening = false
        listener?.cancel()
        listener = nil
    }

    @objc private func toggleLink() {
        if listening {
            dropConnection()
            stopListener()
            setStatus("已断开连接\n点右下角「重连」恢复")
        } else {
            setStatus("正在重新广播…")
            startListener()
        }
        updateLinkButton()
        showControls()
    }

    @objc private func toggleAudio() {
        audioMuted.toggle()
        UserDefaults.standard.set(audioMuted, forKey: "ipadAudioMuted")
        audioStateLock.lock()
        let muted = audioMuted
        audioStateLock.unlock()
        audioQueue.async { [weak self] in
            self?.audioPlayer.volume = muted ? 0 : 1
        }
        if !muted { raiseSystemVolume() }
        updateAudioButton()
        showControls()
    }

    @objc private func toggleMode() {
        scrollMode.toggle()
        UserDefaults.standard.set(scrollMode, forKey: "ipadScrollMode")
        touchView.isScrollMode = scrollMode
        updateModeButton()
        showControls()
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
        formatDescription = nil
        frameIndex = 0
        renderedFrames = 0
        displayLayer.flushAndRemoveImage()
        stopAudio()
    }

    private func configureControl(_ button: UIButton, action: Selector) {
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 18
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func updateAudioButton() {
        audioButton.setTitle(audioMuted ? "声音 关" : "声音 开", for: .normal)
        audioButton.setTitleColor(audioMuted ? UIColor.white.withAlphaComponent(0.55) : .white, for: .normal)
    }

    private func updateModeButton() {
        modeButton.setTitle(scrollMode ? "滑动" : "鼠标", for: .normal)
        modeButton.setTitleColor(scrollMode ? UIColor(red: 0.45, green: 0.85, blue: 1, alpha: 1) : .white,
                                 for: .normal)
    }

    private func updateLinkButton() {
        linkButton.setTitle(listening ? "断开" : "重连", for: .normal)
        linkButton.setTitleColor(listening ? .white : UIColor(red: 0.45, green: 0.85, blue: 1, alpha: 1),
                                 for: .normal)
    }

    private func showControls() {
        fadeWork?.cancel()
        fadeWork = nil
        controlsVisible = true
        controlBar.isUserInteractionEnabled = true
        if controlBar.alpha < 1 {
            UIView.animate(withDuration: 0.2) { self.controlBar.alpha = 1 }
        }
        guard connection != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.hideControls() }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func hideControls() {
        controlsVisible = false
        controlBar.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.6) { self.controlBar.alpha = 0 }
    }

    private func raiseSystemVolume() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            if slider.value < 0.99 { slider.value = 1 }
        }
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
                    self?.showControls()
                case .failed, .cancelled:
                    self?.connection = nil
                    self?.setStatus("连接已断开，等待 Mac 重连…")
                    self?.showControls()
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
        case .keyboard:
            setKeyboardVisible(payload.first == 1)
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
        audioQueue.async { [weak self] in
            self?.startAudio(sampleRate: sampleRate, channels: channels)
        }
    }

    private func startAudio(sampleRate: Double, channels: UInt32) {
        teardownAudio()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)) else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        let failure = IDRunCatchingException { [self] in
            audioEngine.attach(audioPlayer)
            audioAttached = true
            audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: format)
            audioEngine.prepare()
            try? audioEngine.start()
            audioPlayer.play()
        }

        guard failure == nil, audioEngine.isRunning else {
            let reason = failure ?? "音频引擎未启动"
            DispatchQueue.main.async { [weak self] in
                self?.showStatus("音频不可用，画面继续\n\(reason)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.showStatus(nil)
                }
            }
            teardownAudio()
            return
        }

        audioStateLock.lock()
        let muted = audioMuted
        audioStateLock.unlock()
        audioPlayer.volume = muted ? 0 : 1
        if !muted { raiseSystemVolume() }

        audioFormat = format
        audioRunning = true
    }

    private func stopAudio() {
        audioQueue.async { [weak self] in self?.teardownAudio() }
    }

    private func teardownAudio() {
        guard audioRunning || audioFormat != nil || audioAttached else { return }
        audioRunning = false
        audioFormat = nil
        queuedAudioFrames = 0
        if audioAttached {
            audioAttached = false
            audioPlayer.stop()
            audioEngine.stop()
            audioEngine.disconnectNodeOutput(audioPlayer)
            audioEngine.detach(audioPlayer)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func enqueueAudio(_ payload: Data) {
        audioQueue.async { [weak self] in
            guard let self, audioRunning, let format = audioFormat else { return }
            audioStateLock.lock()
            let muted = audioMuted
            audioStateLock.unlock()
            guard !muted else { return }
            let channelCount = Int(format.channelCount)
            guard channelCount > 0 else { return }
            let frames = payload.count / (channelCount * MemoryLayout<Int16>.size)
            guard frames > 0, queuedAudioFrames < Int(format.sampleRate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frames)),
                  let output = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for channel in 0..<channelCount {
                    let target = output[channel]
                    for frame in 0..<frames {
                        target[frame] = Float(base[frame * channelCount + channel]) / 32_768
                    }
                }
            }
            queuedAudioFrames += frames
            audioPlayer.scheduleBuffer(buffer) { [weak self] in
                self?.audioQueue.async { self?.queuedAudioFrames -= frames }
            }
        }
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

    private func sendMessage(_ type: MessageType, payload: Data) {
        guard let connection else { return }
        var header = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(type.rawValue)
        header.append(contentsOf: [0, 0, 0])
        connection.send(content: header + payload, completion: .contentProcessed { _ in })
    }

    private func sendTouch(phase: UInt8, point: CGPoint) {
        let x = Float(point.x / max(view.bounds.width, 1))
        let y = Float(point.y / max(view.bounds.height, 1))
        var payload = Data([phase])
        for value in [x, y] {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        sendMessage(.touch, payload: payload)
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        var payload = Data()
        for value in [Float(dx), Float(dy)] {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        sendMessage(.scroll, payload: payload)
    }

    private func sendInsert(_ text: String) {
        var payload = Data([0])
        payload.append(text.data(using: .utf8) ?? Data())
        sendMessage(.textInput, payload: payload)
    }

    private func setKeyboardVisible(_ visible: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if visible {
                self.keyboardCatcher.becomeFirstResponder()
            } else {
                self.keyboardCatcher.resignFirstResponder()
            }
        }
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
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onRightClick: ((CGPoint) -> Void)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var isScrollMode = false

    private var fingerCount = 0
    private var lastPoint: CGPoint?
    private var dragDistance: CGFloat = 0
    private var scrolled = false
    private var twoFingerStart: Date?
    private var twoFingerOrigin: CGPoint = .zero
    private var twoFingerMoved = false

    private let scrollStep: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches
        if all.count >= 2 {
            fingerCount = all.count
            twoFingerStart = Date()
            twoFingerOrigin = centroid(all)
            twoFingerMoved = false
            return
        }
        guard let touch = touches.first else { return }
        fingerCount = 1
        let point = touch.location(in: self)
        lastPoint = point
        dragDistance = 0
        scrolled = false
        if isScrollMode {
            onMove?(point)
        } else {
            onTouch?(0, point)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches
        if fingerCount >= 2 {
            if let start = twoFingerStart, Date().timeIntervalSince(start) > 0.35 {
                twoFingerMoved = true
            }
            let point = centroid(all)
            if hypot(point.x - twoFingerOrigin.x, point.y - twoFingerOrigin.y) > 16 {
                twoFingerMoved = true
            }
            return
        }
        guard fingerCount == 1, let touch = touches.first, let previous = lastPoint else { return }
        let point = touch.location(in: self)
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        lastPoint = point
        dragDistance += hypot(dx, dy)

        guard isScrollMode else {
            onTouch?(1, point)
            return
        }
        guard dragDistance > 10 else { return }
        scrolled = true
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let scale = scrollStep / length
        onScroll?(dx * scale, dy * scale)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        let remaining = activeFingers(event, fallback: touches)
        if fingerCount >= 2 {
            guard remaining == 0 else { return }
            if !cancelled,
               !twoFingerMoved,
               let start = twoFingerStart,
               Date().timeIntervalSince(start) < 0.6 {
                onRightClick?(twoFingerOrigin)
            }
            fingerCount = 0
            twoFingerStart = nil
            return
        }
        guard fingerCount == 1 else { return }
        fingerCount = 0
        let point = touches.first.map { $0.location(in: self) } ?? lastPoint ?? .zero
        if isScrollMode {
            if !cancelled, !scrolled { onClick?(point) }
        } else {
            onTouch?(2, point)
        }
    }

    private func activeFingers(_ event: UIEvent?, fallback: Set<UITouch>) -> Int {
        guard let all = event?.allTouches else { return fallback.count }
        return all.filter { $0.phase != .ended && $0.phase != .cancelled }.count
    }

    private func centroid(_ all: Set<UITouch>) -> CGPoint {
        let points = all.map { $0.location(in: self) }
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

final class KeyboardCatcher: UIView, UIKeyInput {
    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" {
            onReturn?()
        } else {
            onInsert?(text)
        }
    }

    func deleteBackward() {
        onDelete?()
    }
}
