import Foundation

/// What `capture_screen` shoots. Chosen in Settings → Screen — one dropdown whose entire-display
/// entries also carry the display choice (`DisplaySection`); persisted via
/// `ScreenCapturePreferences` and read at capture time.
public enum ScreenCaptureScope: String, Sendable {
    /// The frontmost app window, wherever it lives — follows clicks/typing across displays, drops
    /// the clutter around it, and enables the OCR text sidecar. The default.
    case activeWindow
    /// The full display picked in the same dropdown (`ScreenCapturePreferences.displayIndex`).
    case entireDisplay
}
