import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionState: String {
    case granted
    case denied
    case unknown
}

enum Permissions {
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.loop.ipadextendeddisplay"
    }

    static var screenRecording: PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return .unknown
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var accessibility: PermissionState {
        AXIsProcessTrusted() ? .granted : .unknown
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func resetScreenRecording() -> Bool {
        runTCCUtil(service: "ScreenCapture")
    }

    @discardableResult
    static func resetAccessibility() -> Bool {
        runTCCUtil(service: "Accessibility")
    }

    private static func runTCCUtil(service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
