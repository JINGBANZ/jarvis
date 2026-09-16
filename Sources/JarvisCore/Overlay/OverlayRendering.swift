import Foundation

/// What the overlay needs to do; the real NSPanel impl lives in JarvisOverlay.
public protocol OverlayRendering: AnyObject {
    /// Sampled at delivery, since the user can hide the persistent surface during a request.
    @MainActor var acceptsDetail: Bool { get }
    /// Render the hint and its detail, and report the detail that reached the screen, in one
    /// main-actor operation. Nil means nothing was shown: the box is hidden, or the detail had
    /// nothing left to draw once its unusable blocks were removed.
    @MainActor func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                            detail: ReplyDetail?) -> ReplyDetail?
    /// Render `lines` one at a time, each shown for the matching entry in `perLineSeconds` (so a
    /// line's time can scale with its length — see `OverlayTiming`). The brain returns the lines
    /// already split (the `speak` tool's `lines` array), so there is no client-side sentence splitting.
    /// `perLineSeconds` is expected to align with `lines`; a shorter array just truncates safely.
    func render(_ lines: [String], perLineSeconds: [TimeInterval])
    func render(_ lines: [String], perLineSeconds: [TimeInterval], detail: ReplyDetail?)
}

extension OverlayRendering {
    @MainActor public var acceptsDetail: Bool { false }

    @MainActor public func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                                   detail: ReplyDetail?) -> ReplyDetail? {
        let shown = acceptsDetail ? detail : nil
        render(lines, perLineSeconds: perLineSeconds, detail: shown)
        return shown?.hasContent == true ? shown : nil
    }

    /// Text-only sinks, such as the transient caption, retain their normal behavior.
    public func render(_ lines: [String], perLineSeconds: [TimeInterval], detail: ReplyDetail?) {
        render(lines, perLineSeconds: perLineSeconds)
    }

    /// Convenience: show every line for the same duration. Handy for callers/tests that don't need
    /// per-line scaling.
    public func render(_ lines: [String], perLineSeconds: TimeInterval) {
        render(lines, perLineSeconds: Array(repeating: perLineSeconds, count: lines.count))
    }
}
