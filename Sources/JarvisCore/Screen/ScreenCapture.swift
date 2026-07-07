import Foundation

/// Returns a screenshot (plus optional OCR text) for the brain, or nil on failure.
public protocol ScreenCapturing: Sendable {
    func capture() -> ScreenSnapshot?
}

/// Uses the built-in `screencapture -x -t jpg` (silent). Captures the display selected in Settings
/// (`ScreenCapturePreferences`, read at capture time so a change applies to the very next screenshot);
/// the default is the main display. A stale selection — e.g. the chosen external monitor was
/// unplugged — makes `screencapture -D` fail, and we fall back to the main display rather than
/// dropping the screenshot. Also the fallback for `WindowScopedScreenCapture` (JarvisApp) when no
/// eligible window is on screen.
/// NOTE: excluding Jarvis's own overlay window is handled by the overlay being a non-capturable
/// panel (sharingType = .none) in JarvisOverlay; see OverlayCaptionPanel and wiki/overlay-invisibility.md
/// (verified: the overlay never appears in this CLI's output on macOS 26.5).
public struct ScreenCaptureCLI: ScreenCapturing {
    private let preferences: ScreenCapturePreferences

    public init(preferences: ScreenCapturePreferences = ScreenCapturePreferences()) {
        self.preferences = preferences
    }

    public func capture() -> ScreenSnapshot? {
        let display = preferences.displayIndex
        if display > 1, let jpeg = Self.runScreencapture(arguments: ["-x", "-t", "jpg", "-D", "\(display)"]) {
            return ScreenSnapshot(imageBase64: jpeg.base64EncodedString())
        }
        // Index 1 needs no -D (plain capture IS the main display); also the stale-index fallback.
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
