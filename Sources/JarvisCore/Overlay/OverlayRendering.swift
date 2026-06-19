import Foundation

/// What the overlay needs to do; the real NSPanel impl lives in JarvisOverlay.
public protocol OverlayRendering: AnyObject {
    /// Render `lines` one at a time, each shown for the matching entry in `perLineSeconds` (so a
    /// line's time can scale with its length — see `OverlayTiming`). The brain returns the lines
    /// already split (the `speak` tool's `lines` array), so there is no client-side sentence splitting.
    /// `perLineSeconds` is expected to align with `lines`; a shorter array just truncates safely.
    func render(_ lines: [String], perLineSeconds: [TimeInterval])
}

extension OverlayRendering {
    /// Convenience: show every line for the same duration. Handy for callers/tests that don't need
    /// per-line scaling.
    public func render(_ lines: [String], perLineSeconds: TimeInterval) {
        render(lines, perLineSeconds: Array(repeating: perLineSeconds, count: lines.count))
    }
}
