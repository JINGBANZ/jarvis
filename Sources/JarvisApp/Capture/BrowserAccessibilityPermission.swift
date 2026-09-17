@preconcurrency import ApplicationServices
import Foundation

/// Live capture only reads `isGranted`; `request` is reachable only from Settings while stopped.
@MainActor
enum BrowserAccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    static func request() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // ghost-mode-allowed: explicit user action in Settings while no session or teardown is live
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}
