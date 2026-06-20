import AppKit

extension NSPanel {
    /// Exclude this panel from ALL screen capture by setting `sharingType = .none`.
    ///
    /// This one flag does double duty: it keeps the panel out of Jarvis's own `capture_screen` shots
    /// (so the brain never reads its own output) AND hides it from anyone else's screen share or
    /// recording (Zoom/Meet/Teams/QuickTime). It is the same OS mechanism every comparable tool uses
    /// (Electron's setContentProtection / Tauri's contentProtected both map to it); there is no other
    /// public API. Verified on macOS 26.5 across the screencapture CLI, SCScreenshotManager, and a live
    /// SCStream. Both `OverlayPanel` and `ResponseLogPanel` rely on it, and both re-assert it on show:
    /// an NSApp activation-policy flip (e.g. opening the Settings window) can make WindowServer drop
    /// `sharingType` on some macOS versions/configs. See wiki/overlay-invisibility.md.
    func excludeFromScreenCapture() {
        sharingType = .none
    }
}
