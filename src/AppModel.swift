import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct DisplayDevice: Identifiable, Hashable {
    enum Transport: String {
        case usb = "USB"
        case wifi = "Wi-Fi"
    }

    let id: String
    let name: String
    let detail: String
    let transport: Transport
    let usbDeviceID: Int?
    let host: String?
    let port: UInt16

    var isUSB: Bool { transport == .usb }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case streaming
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "未连接"
            case .preparing: return "正在准备"
            case .streaming: return "推流中"
            case .failed: return "连接失败"
            }
        }

        var isBusy: Bool { self == .preparing || self == .streaming }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var devices: [DisplayDevice] = []
    @Published var selectedDeviceID: String?
    @Published var preset: DisplayPreset = DisplayPreset.all[0]
    @Published var refreshRate: Double = 60
    @Published var bitrateMbps: Int = 12
    @Published var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
            guard audioEnabled != oldValue else { return }
            append(audioEnabled ? "已开启音频透传" : "已关闭音频透传（声音留在 Mac）")
            if phase == .streaming { restartStream() }
        }
    }
    @Published var runInBackground: Bool {
        didSet { UserDefaults.standard.set(runInBackground, forKey: "runInBackground") }
    }
    @Published private(set) var stats = StreamStats()
    @Published private(set) var logs: [String] = []
    @Published private(set) var screenPermission: PermissionState = Permissions.screenRecording
    @Published private(set) var accessibilityPermission: PermissionState = Permissions.accessibility
    @Published private(set) var virtualDisplayReady = false
    @Published private(set) var needsRelaunch = false
    @Published private(set) var permissionTrouble: String?
    @Published private(set) var locationWarning: String?

    private var virtualDisplay: VirtualDisplay?
    private var engine: StreamEngine?
    private var scDisplay: SCDisplay?
    private let port: UInt16 = 12346
    private let wifiDiscovery = WifiDiscovery()
    private var wifiDevices: [WifiDisplay] = []
    private var usbDevices: [DisplayDevice] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["runInBackground": true, "audioEnabled": false])
        audioEnabled = defaults.bool(forKey: "audioEnabled")
        runInBackground = defaults.bool(forKey: "runInBackground")

        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") {
            locationWarning = "正在从磁盘映像里运行。请先把「iPad 扩展屏」拖到「应用程序」再打开，否则每次启动路径都不同，系统权限永远记不住。"
        } else if path.contains("/AppTranslocation/") {
            locationWarning = "应用正在被 Gatekeeper 随机路径运行，系统权限无法保存。请把 App 拖到「应用程序」后重新打开。"
        }

        wifiDiscovery.onChange = { [weak self] found in
            Task { @MainActor in
                self?.wifiDevices = found
                self?.rebuildDeviceList()
            }
        }
    }

    var selectedDevice: DisplayDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var canStart: Bool {
        selectedDevice != nil && !phase.isBusy
    }

    func refreshPermissions() {
        let previous = screenPermission
        screenPermission = Permissions.screenRecording
        accessibilityPermission = Permissions.accessibility
        if previous != .granted, screenPermission == .granted {
            needsRelaunch = true
            append("屏幕录制权限已生效，需要重启应用才能采集画面")
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(path)\""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    func repairPermissions() {
        append("正在重置本应用的权限记录…")
        let screen = Permissions.resetScreenRecording()
        let accessibility = Permissions.resetAccessibility()
        append(screen && accessibility
               ? "已重置屏幕录制与辅助功能授权，重启后请重新授权"
               : "重置未完全成功，请到系统设置里手动删除本应用条目再重新添加")
        screenPermission = Permissions.screenRecording
        accessibilityPermission = Permissions.accessibility
        permissionTrouble = nil
        relaunch()
    }

    func requestScreenPermission() {
        Permissions.requestScreenRecording()
        append("已请求屏幕录制权限，授权后请重启本应用")
        refreshPermissions()
    }

    func requestAccessibilityPermission() {
        Permissions.requestAccessibility()
        append("已请求辅助功能权限（用于把 iPad 触控变鼠标）")
        refreshPermissions()
    }

    func startDiscovery() {
        wifiDiscovery.start()
    }

    func refreshDevices() {
        var usb: [DisplayDevice] = []
        do {
            let merged = try Usbmux.listDevices()
            var byUDID: [String: MuxDevice] = [:]
            for device in merged {
                if let existing = byUDID[device.udid], existing.isUSB, !device.isUSB { continue }
                byUDID[device.udid] = device
            }
            usb = byUDID.values.filter { $0.isUSB }.map { device in
                DisplayDevice(id: "usb-" + device.udid,
                              name: device.model ?? "iPad",
                              detail: device.shortUDID,
                              transport: .usb,
                              usbDeviceID: device.deviceID,
                              host: nil,
                              port: port)
            }
        } catch {
            append("USB 设备列表读取失败：\(error.localizedDescription)")
        }
        usbDevices = usb
        rebuildDeviceList()
    }

    private func rebuildDeviceList() {
        let wifi = wifiDevices.map { display in
            DisplayDevice(id: "wifi-" + display.name,
                          name: display.name,
                          detail: "\(display.host):\(display.port)",
                          transport: .wifi,
                          usbDeviceID: nil,
                          host: display.host,
                          port: UInt16(display.port))
        }
        let merged = usbDevices + wifi
        devices = merged
        if selectedDeviceID == nil || !merged.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = merged.first(where: { $0.isUSB })?.id ?? merged.first?.id
        }
        if !merged.isEmpty {
            append("发现 \(merged.count) 台设备：" + merged.map { "\($0.name)(\($0.transport.rawValue))" }.joined(separator: "、"))
        }
    }

    func start() {
        guard let device = selectedDevice else {
            phase = .failed("没有可用设备")
            return
        }
        guard screenPermission == .granted else {
            phase = .failed("缺少屏幕录制权限")
            append("请先在系统设置 → 隐私与安全性 → 屏幕录制 中勾选本应用")
            Permissions.requestScreenRecording()
            Permissions.openPrivacyPane(anchor: "Privacy_ScreenCapture")
            return
        }
        if accessibilityPermission != .granted {
            append("提醒：未授予辅助功能权限，画面能看但触控无效")
        }
        phase = .preparing
        append("连接 \(device.name) · \(device.transport.rawValue) …")

        Task {
            do {
                let display = try ensureVirtualDisplay()
                let content = try await shareableDisplay(matching: display.displayID)
                try await runEngine(device: device, display: content, bounds: display.bounds,
                                    captureSize: display.pixelSize)
            } catch {
                phase = .failed(error.localizedDescription)
                append(error.localizedDescription)
                if isPermissionError(error.localizedDescription) {
                    permissionTrouble = "系统里可能显示已授权，但旧授权记录对不上当前版本（ad-hoc 签名每次构建都会变）。点下面的按钮重置后重启即可。"
                }
            }
        }
    }

    private func isPermissionError(_ text: String) -> Bool {
        let markers = ["3801", "declined", "TCC", "not authorized", "无权限", "拒绝", "屏幕录制"]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    func stop() {
        engine?.stop()
        engine = nil
        phase = .idle
        stats = StreamStats()
        append("已断开连接，虚拟屏幕保留在「显示器」设置中")
    }

    func dismissPermissionTrouble() {
        permissionTrouble = nil
    }

    func applyPreset(_ preset: DisplayPreset) {
        self.preset = preset
        guard let virtualDisplay else { return }
        do {
            try virtualDisplay.apply(preset, refreshRate: refreshRate)
            append("虚拟屏切换为 \(preset.title) · \(Int(refreshRate))Hz")
            if phase == .streaming { restartStream() }
        } catch {
            append("切换失败：\(error.localizedDescription)")
        }
    }

    func applyRefreshRate(_ rate: Double) {
        refreshRate = rate
        guard let virtualDisplay else { return }
        do {
            try virtualDisplay.apply(preset, refreshRate: rate)
            append("刷新率切换为 \(Int(rate))Hz")
            if phase == .streaming { restartStream() }
        } catch {
            append("切换失败：\(error.localizedDescription)")
        }
    }

    private func restartStream() {
        guard let device = selectedDevice else { return }
        engine?.stop()
        engine = nil
        phase = .preparing
        Task {
            do {
                let display = try ensureVirtualDisplay()
                let content = try await shareableDisplay(matching: display.displayID)
                try await runEngine(device: device, display: content, bounds: display.bounds,
                                    captureSize: display.pixelSize)
            } catch {
                phase = .failed(error.localizedDescription)
                append(error.localizedDescription)
            }
        }
    }

    private func ensureVirtualDisplay() throws -> VirtualDisplay {
        if let virtualDisplay { return virtualDisplay }
        var created: VirtualDisplay?
        for attempt in 0..<3 {
            do {
                created = try VirtualDisplay(name: "iPad 扩展屏")
                break
            } catch {
                if attempt == 2 { throw error }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        guard let created else {
            throw VirtualDisplayError.createFailed
        }
        virtualDisplay = created
        virtualDisplayReady = true
        append("已创建虚拟屏幕 #\(created.displayID) · \(preset.title)")
        do {
            try created.apply(preset, refreshRate: refreshRate)
        } catch {
            append("分辨率切换被系统拒绝，已保持当前模式：\(error.localizedDescription)")
        }
        return created
    }

    private func shareableDisplay(matching id: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 0..<15 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let match = content.displays.first(where: { $0.displayID == id }) {
                return match
            }
            if attempt == 14 {
                throw StreamEngineError.capture("系统未把虚拟屏幕暴露给采集接口")
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw StreamEngineError.capture("虚拟屏幕不可用")
    }

    private func runEngine(device: DisplayDevice, display: SCDisplay, bounds: CGRect,
                           captureSize: CGSize) async throws {
        let fd: Int32
        do {
            if let host = device.host {
                fd = try Usbmux.connect(host: host, port: device.port)
            } else if let deviceID = device.usbDeviceID {
                fd = try Usbmux.connect(deviceID: deviceID, port: device.port)
            } else {
                throw StreamEngineError.tunnel("设备信息不完整")
            }
        } catch {
            throw StreamEngineError.tunnel(error.localizedDescription)
        }
        let engine = StreamEngine()
        engine.onLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        engine.onStats = { [weak self] snapshot in
            Task { @MainActor in
                self?.stats = snapshot
                self?.screenPermission = Permissions.screenRecording
                self?.accessibilityPermission = Permissions.accessibility
            }
        }
        engine.onConnected = { [weak self] in
            Task { @MainActor in self?.phase = .streaming }
        }
        engine.onDisconnect = { [weak self] reason in
            Task { @MainActor in
                self?.phase = .idle
                self?.append(reason)
            }
        }
        self.engine = engine
        try await engine.start(tunnelFD: fd,
                               display: display, displayBounds: bounds, captureSize: captureSize,
                               audio: audioEnabled,
                               fps: Int(refreshRate), bitrate: bitrateMbps * 1_000_000)
        phase = .streaming
        append("画面已推送到 iPad，可直接用 iPad 触摸操作")
    }

    func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(line)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
}
