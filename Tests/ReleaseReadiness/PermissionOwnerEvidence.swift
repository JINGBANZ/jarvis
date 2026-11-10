import AppKit
import ApplicationServices
import Security

@MainActor
enum PermissionOwnerEvidence {
    static func record(directory: URL, filename: String) throws {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 2)
        var focusedValue: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        var focusedPID: pid_t = 0
        var role = "unavailable"
        if focusResult == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, 2)
            if AXUIElementGetPid(focused, &focusedPID) != .success { focusedPID = 0 }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &value) == .success,
               let name = value as? String,
               ["AXApplication", "AXWindow", "AXDialog", "AXButton", "AXTextField", "AXSecureTextField"].contains(name) {
                role = name
            }
        }
        let receipt: [String: Any] = ["frontmost": owner(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
                                     "focused": owner(focusedPID), "focusReadStatus": focusResult.rawValue,
                                     "focusedRole": role]
        try JSONSerialization.data(withJSONObject: receipt).write(
            to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private static func owner(_ pid: pid_t) -> [String: Any] {
        var value: [String: Any] = ["pid": pid, "verifiedAppleOwner": false, "identifier": "unavailable",
                                  "executable": "unavailable", "windowCount": -1, "windowsReadStatus": 0]
        guard pid > 0 else { return value }
        var code: SecCode?
        let flags = SecCSFlags(rawValue: 0)
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, flags, &code) == errSecSuccess, let code else { return value }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, flags, &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return value }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { return value }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              identifier.range(of: #"^com\.apple\.[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil,
              let executable = information[kSecCodeInfoMainExecutable as String] as? URL else { return value }
        let path = executable.resolvingSymlinksInPath().path
        guard path.hasPrefix("/System/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.ownerAccountID] as? NSNumber == 0 else { return value }
        value["verifiedAppleOwner"] = true
        value["identifier"] = identifier
        value["executable"] = path
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        value["windowsReadStatus"] = result.rawValue
        if result == .success, let windows = windows as? [AXUIElement], windows.count <= 256 {
            value["windowCount"] = windows.count
        }
        return value
    }
}
