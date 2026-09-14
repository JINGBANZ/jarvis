@preconcurrency import ApplicationServices
import Foundation

/// Optional browser-text grant. Live capture only reads `isGranted`; the prompt path is reachable
/// solely from the explicit Screen Settings control while the session lifecycle is stopped.
@MainActor
enum BrowserAccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    static func request() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // ghost-mode-allowed: explicit user action in Settings while no session or teardown is live
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}
