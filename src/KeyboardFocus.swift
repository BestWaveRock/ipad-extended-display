import ApplicationServices
import Foundation

enum KeyboardFocus {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXComboBox",
        "AXSearchField"
    ]

    static func isTextInputFocused() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let axElement = unsafeBitCast(element, to: AXUIElement.self)

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role) == .success,
              let roleText = role as? String else { return false }
        if textRoles.contains(roleText) { return true }

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleText = subrole as? String,
           subroleText == "AXSearchField" {
            return true
        }
        return false
    }
}
