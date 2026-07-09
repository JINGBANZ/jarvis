import Foundation

/// What `capture_screen` shoots. Chosen in Settings → Screen; persisted via
/// `ScreenCapturePreferences` and read at capture time. Mirrors `ReasoningEffort`'s shape.
public enum ScreenCaptureScope: String, Sendable, CaseIterable {
    /// The frontmost app window, wherever it lives — follows clicks/typing across displays, drops
    /// the clutter around it, and enables the OCR text sidecar. The default.
    case activeWindow
    /// The full display selected in Settings (also the fallback when no window is eligible).
    case entireDisplay

    /// Menu title for the Settings popup.
    public var title: String {
        switch self {
        case .activeWindow: return "Active window (recommended)"
        case .entireDisplay: return "Entire display"
        }
    }
}
