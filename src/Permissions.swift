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
}
