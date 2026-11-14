import CoreGraphics
import Foundation

struct DisplayPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    var aspectRatio: Double { Double(pointWidth) / Double(pointHeight) }

    static let all: [DisplayPreset] = [
        DisplayPreset(id: "1024", title: "1024 × 768",
                      detail: "Retina 缩放 · 字大清晰 · 推荐",
                      pointWidth: 1024, pointHeight: 768,
                      pixelWidth: 2048, pixelHeight: 1536),
        DisplayPreset(id: "1280", title: "1280 × 960",
                      detail: "标准缩放 · 折中",
                      pointWidth: 1280, pointHeight: 960,
                      pixelWidth: 1280, pixelHeight: 960),
        DisplayPreset(id: "1600", title: "1600 × 1200",
                      detail: "标准缩放 · 视野更大",
                      pointWidth: 1600, pointHeight: 1200,
                      pixelWidth: 1600, pixelHeight: 1200),
        DisplayPreset(id: "2048", title: "2048 × 1536",
                      detail: "1:1 像素 · 桌面最大 · 字最小",
                      pointWidth: 2048, pointHeight: 1536,
                      pixelWidth: 2048, pixelHeight: 1536)
    ]
}

enum VirtualDisplayError: LocalizedError {
    case privateAPIUnavailable
    case createFailed
    case modeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            return "当前系统不支持 CGVirtualDisplay 虚拟屏幕"
        case .createFailed:
            return "虚拟屏幕创建失败，请重试"
        case .modeUnavailable(let name):
            return "无法切换到 \(name) 分辨率"
        }
    }
}

private typealias FnAlloc = @convention(c) (AnyObject, Selector) -> AnyObject?
private typealias FnInitObject = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
private typealias FnInitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
private typealias FnApply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
private typealias FnDisplayID = @convention(c) (AnyObject, Selector) -> UInt32

final class VirtualDisplay {
    static let pixelWidth = 2048
    static let pixelHeight = 1536

    let displayID: CGDirectDisplayID
    private let display: AnyObject
    private let msgSend: UnsafeMutableRawPointer

    init(name: String) throws {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend"),
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") else {
            throw VirtualDisplayError.privateAPIUnavailable
        }
        msgSend = symbol

        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(UInt32(VirtualDisplay.pixelWidth), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(VirtualDisplay.pixelHeight), forKey: "maxPixelsHigh")
        descriptor.setValue(NSSize(width: 197, height: 148), forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0x1A2B), forKey: "vendorID")
        descriptor.setValue(UInt32(0x3C4D), forKey: "productID")
        descriptor.setValue(UInt32(1), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        let alloc = unsafeBitCast(symbol, to: FnAlloc.self)
        let initWithDescriptor = unsafeBitCast(symbol, to: FnInitObject.self)
        guard let allocated = alloc(displayClass, NSSelectorFromString("alloc")),
              let created = initWithDescriptor(allocated,
                                               NSSelectorFromString("initWithDescriptor:"),
                                               descriptor) else {
            throw VirtualDisplayError.createFailed
        }
        display = created

        let initMode = unsafeBitCast(symbol, to: FnInitMode.self)
        var modes: [AnyObject] = []
        for preset in DisplayPreset.all {
            for refresh in [30.0, 60.0] {
                guard let modeAllocated = alloc(modeClass, NSSelectorFromString("alloc")),
                      let mode = initMode(modeAllocated,
                                          NSSelectorFromString("initWithWidth:height:refreshRate:"),
                                          UInt32(preset.pixelWidth),
                                          UInt32(preset.pixelHeight),
                                          refresh) else { continue }
                modes.append(mode)
            }
        }
        let settings = settingsClass.init()
        settings.setValue(modes, forKey: "modes")
        let applySettings = unsafeBitCast(symbol, to: FnApply.self)
        _ = applySettings(created, NSSelectorFromString("applySettings:"), settings)
        let readID = unsafeBitCast(symbol, to: FnDisplayID.self)
        displayID = readID(created, NSSelectorFromString("displayID"))
        guard displayID != 0 else {
            throw VirtualDisplayError.createFailed
        }
        Thread.sleep(forTimeInterval: 1.0)
        try? apply(DisplayPreset.all[0], refreshRate: 60)
    }

    func apply(_ preset: DisplayPreset, refreshRate: Double) throws {
        let target = try mode(for: preset, refreshRate: refreshRate)
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.width == target.width,
           current.height == target.height,
           current.pixelWidth == target.pixelWidth,
           current.pixelHeight == target.pixelHeight,
           abs(current.refreshRate - target.refreshRate) < 1.5 {
            return
        }

        for attempt in 0..<3 {
            var configuration: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configuration) == .success else {
                throw VirtualDisplayError.modeUnavailable(preset.title)
            }
            CGConfigureDisplayWithDisplayMode(configuration, displayID, target, nil)
            let result = CGCompleteDisplayConfiguration(configuration, .forSession)
            Thread.sleep(forTimeInterval: 0.4)
            if result == .success || isCurrent(target) {
                return
            }
            Thread.sleep(forTimeInterval: 0.5 + Double(attempt) * 0.5)
        }
        throw VirtualDisplayError.modeUnavailable(preset.title)
    }

    private func isCurrent(_ mode: CGDisplayMode) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
        guard current.width == mode.width,
              current.height == mode.height,
              current.pixelWidth == mode.pixelWidth,
              current.pixelHeight == mode.pixelHeight else { return false }
        if current.refreshRate <= 0 { return true }
        return abs(current.refreshRate - mode.refreshRate) < 1.5
    }

    private func mode(for preset: DisplayPreset, refreshRate: Double) throws -> CGDisplayMode {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for _ in 0..<8 {
            if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] {
                if let exact = modes.first(where: {
                    $0.width == preset.pointWidth && $0.height == preset.pointHeight
                        && $0.pixelWidth == preset.pixelWidth && $0.pixelHeight == preset.pixelHeight
                        && abs($0.refreshRate - refreshRate) < 1.5
                }) { return exact }
                if let pixelMatch = modes.first(where: {
                    $0.pixelWidth == preset.pixelWidth && $0.pixelHeight == preset.pixelHeight
                        && abs($0.refreshRate - refreshRate) < 1.5
                }) { return pixelMatch }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw VirtualDisplayError.modeUnavailable(preset.title)
    }

    var pixelSize: CGSize {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
        }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    var pointSize: CGSize { CGDisplayBounds(displayID).size }
    var bounds: CGRect { CGDisplayBounds(displayID) }
}
