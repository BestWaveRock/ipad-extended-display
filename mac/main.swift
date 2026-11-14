import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct Arguments {
    var presetID = "1024"
    var refresh = 60.0
    var bitrateMbps = 12
    var port: UInt16 = 12346
    var host: String?
}

func parseArguments() -> Arguments {
    var arguments = Arguments()
    let values = CommandLine.arguments
    var index = 1
    while index < values.count {
        let key = values[index]
        let value = index + 1 < values.count ? values[index + 1] : nil
        switch key {
        case "--preset":
            if let value { arguments.presetID = value }
            index += 2
        case "--refresh":
            if let value, let refresh = Double(value) { arguments.refresh = refresh }
            index += 2
        case "--bitrate":
            if let value, let bitrate = Int(value) { arguments.bitrateMbps = bitrate }
            index += 2
        case "--port":
            if let value, let port = UInt16(value) { arguments.port = port }
            index += 2
        case "--host":
            arguments.host = value
            index += 2
        default:
            index += 1
        }
    }
    return arguments
}

func log(_ line: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write(Data("[\(formatter.string(from: Date()))] \(line)\n".utf8))
}

let arguments = parseArguments()
let preset = DisplayPreset.all.first { $0.id == arguments.presetID } ?? DisplayPreset.all[0]

func connectTunnel(_ arguments: Arguments) throws -> Int32 {
    if let host = arguments.host {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = arguments.port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StreamEngineError.tunnel("socket 创建失败") }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw StreamEngineError.tunnel("连接 \(host):\(arguments.port) 失败")
        }
        log("已连接 \(host):\(arguments.port)")
        return fd
    }
    guard let device = try Usbmux.listDevices().first(where: { $0.isUSB }) else {
        throw StreamEngineError.tunnel("没有通过 USB 连接的设备")
    }
    log("设备 \(device.udid)")
    return try Usbmux.connect(deviceID: device.deviceID, port: arguments.port)
}

let ready = DispatchSemaphore(value: 0)
var startupError: String?
var retainedEngine: StreamEngine?
var retainedDisplay: VirtualDisplay?

Task {
    do {
        let tunnelFD = try connectTunnel(arguments)
        let virtualDisplay = try VirtualDisplay(name: "iPad 扩展屏")
        retainedDisplay = virtualDisplay
        try virtualDisplay.apply(preset, refreshRate: arguments.refresh)
        log("虚拟屏 \(preset.title) · 像素 \(Int(virtualDisplay.pixelSize.width))×\(Int(virtualDisplay.pixelSize.height))")

        var target: SCDisplay?
        for _ in 0..<15 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == virtualDisplay.displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let target else {
            throw StreamEngineError.capture("采集接口没有暴露虚拟屏幕，请检查屏幕录制权限")
        }

        let engine = StreamEngine()
        engine.onLog = { log($0) }
        engine.onStats = { stats in
            log(String(format: "%.1f fps · %.1f MB/s · 触控 %d · 丢帧 %d",
                       stats.fps, stats.megabytesPerSecond, stats.touches, stats.dropped))
        }
        engine.onDisconnect = { reason in
            log(reason)
            exit(0)
        }
        try await engine.start(tunnelFD: tunnelFD,
                               display: target, displayBounds: virtualDisplay.bounds,
                               captureSize: virtualDisplay.pixelSize,
                               fps: Int(arguments.refresh), bitrate: arguments.bitrateMbps * 1_000_000)
        retainedEngine = engine
    } catch {
        startupError = error.localizedDescription
    }
    ready.signal()
}

ready.wait()
if let startupError {
    log(startupError)
    exit(1)
}
log("推流中，Ctrl-C 结束")
dispatchMain()
