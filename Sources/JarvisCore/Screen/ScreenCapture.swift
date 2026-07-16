import Foundation

/// Returns a screenshot (plus optional OCR text) for the brain, or nil on failure.
public protocol ScreenCapturing: Sendable {
    func capture() -> ScreenSnapshot?
}

/// Uses the built-in `screencapture -x -t jpg` (silent). In entire-display scope it shoots the
/// display chosen in Settings (`ScreenCapturePreferences`, read at capture time so a change applies
/// to the very next screenshot), reshooting the main display when `-D` fails — e.g. the chosen
/// external monitor was unplugged — rather than dropping the screenshot. In active-window scope it
/// is the fallback for `WindowScopedScreenCapture` (JarvisApp) when no eligible window is on
/// screen, and always shoots the main display: a display index left over from an old
/// entire-display selection must not steer fallbacks.
/// NOTE: excluding Jarvis's own overlay window is handled by the overlay being a non-capturable
/// panel (sharingType = .none) in JarvisOverlay; see OverlayCaptionPanel and wiki/overlay-invisibility.md
/// (verified: the overlay never appears in this CLI's output on macOS 26.5).
public struct ScreenCaptureCLI: ScreenCapturing {
    private let preferences: ScreenCapturePreferences

    public init(preferences: ScreenCapturePreferences = ScreenCapturePreferences()) {
        self.preferences = preferences
    }

    public func capture() -> ScreenSnapshot? {
        // Which display (if any) needs explicit targeting is the preferences' decision; a stale
        // -D pointing at a disconnected display fails, and we fall through to the plain capture.
        if let display = preferences.explicitDisplay,
           let jpeg = Self.runScreencapture(arguments: ["-x", "-t", "jpg", "-D", "\(display)"]) {
            return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
        }
        // A plain capture IS the main display — no -D needed.
        guard let jpeg = Self.runScreencapture(arguments: ["-x", "-t", "jpg"]) else { return nil }
        return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
    }

    /// Runs `screencapture` with `arguments` + a tmpfile path, returning the captured image bytes.
    /// Shared with `WindowScopedScreenCapture` (JarvisApp), which adds `-l <windowID>`.
    public static func runScreencapture(arguments: [String]) -> Data? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = arguments + [tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: tmp)
    }
}
