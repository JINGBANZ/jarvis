import Foundation

/// Returns a screenshot (plus optional OCR text) for the brain, or nil on failure.
public protocol ScreenCapturing: Sendable {
    func capture() -> ScreenSnapshot?
    /// Stop an in-flight capture and make `capture()` return only after its helper and transient
    /// file have been cleaned up.
    func cancelCapture()
}

/// Uses the built-in `screencapture -x -t jpg` (silent). In entire-display scope it shoots the
/// display chosen in Settings (`ScreenCapturePreferences`, read at capture time so a change applies
/// to the very next screenshot), reshooting the main display when `-D` fails — e.g. the chosen
/// external monitor was unplugged — rather than dropping the screenshot. A cleanup-integrity failure
/// never falls through to that retry. In active-window scope it is the fallback for
/// `WindowScopedScreenCapture` (JarvisApp) when no eligible window is on screen, and always shoots
/// the main display: a display index left over from an old entire-display selection must not steer
/// fallbacks.
/// NOTE: excluding Jarvis's own overlay window is handled by the overlay being a non-capturable
/// panel (sharingType = .none) in JarvisOverlay; see OverlayCaptionPanel and wiki/overlay-invisibility.md
/// (verified: the overlay never appears in this CLI's output on macOS 26.5).
public struct ScreenCaptureCLI: ScreenCapturing {
    private let preferences: ScreenCapturePreferences
    private let runner: ScreenCaptureRunner

    public init(preferences: ScreenCapturePreferences, runner: ScreenCaptureRunner) {
        self.preferences = preferences
        self.runner = runner
    }

    public func capture() -> ScreenSnapshot? {
        // Which display (if any) needs explicit targeting is the preferences' decision; a stale
        // -D pointing at a disconnected display fails, and we fall through to the plain capture.
        if let display = preferences.explicitDisplay {
            switch runner.capture(arguments: ["-x", "-t", "jpg", "-D", "\(display)"]) {
            case let .captured(jpeg):
                return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
            case .cleanupFailed, .cancelled:
                return nil
            case .failed:
                break
            }
        }
        // A plain capture IS the main display — no -D needed.
        switch runner.capture(arguments: ["-x", "-t", "jpg"]) {
        case let .captured(jpeg):
            return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
        case .failed, .cleanupFailed, .cancelled:
            return nil
        }
    }

    public func cancelCapture() {
        runner.cancelCapture()
    }
}
