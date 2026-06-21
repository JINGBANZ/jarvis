import Foundation

/// Returns a screenshot of the active display as base64-encoded JPEG, or nil on failure.
public protocol ScreenCapturing: Sendable {
    func capture() -> String?
}

/// Uses the built-in `screencapture -x -t jpg` (silent). The main display only.
/// NOTE: excluding Jarvis's own overlay window is handled by the overlay being a non-capturable
/// panel (sharingType = .none) in JarvisOverlay; see OverlayCaptionPanel and wiki/overlay-invisibility.md
/// (verified: the overlay never appears in this CLI's output on macOS 26.5).
public struct ScreenCaptureCLI: ScreenCapturing {
    public init() {}

    public func capture() -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-t", "jpg", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp) else { return nil }
        return data.base64EncodedString()
    }
}
