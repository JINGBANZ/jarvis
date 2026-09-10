import Foundation

/// What the overlay needs to do; the real NSPanel impl lives in JarvisOverlay.
public protocol OverlayRendering: AnyObject {
    /// Deliver or clear the independent code area and report accepted visible content.
    @MainActor func deliverCodeSnippet(_ snippet: CodeSnippet?) -> CodeSnippet?
    /// Sampled at delivery, since the user can hide the persistent surface during a request.
    @MainActor var acceptsDetail: Bool { get }
    /// Render and report accepted detail in one main-actor operation.
    @MainActor func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                            diagram: DiagramHint?, explanation: String?) -> String?
    /// Render `lines` one at a time, each shown for the matching entry in `perLineSeconds` (so a
    /// line's time can scale with its length — see `OverlayTiming`). The brain returns the lines
    /// already split (the `speak` tool's `lines` array), so there is no client-side sentence splitting.
    /// `perLineSeconds` is expected to align with `lines`; a shorter array just truncates safely.
    func render(_ lines: [String], perLineSeconds: [TimeInterval])
    func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?)
    func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?, explanation: String?)
}

extension OverlayRendering {
    @MainActor public func deliverCodeSnippet(_ snippet: CodeSnippet?) -> CodeSnippet? { nil }
    @MainActor public var acceptsDetail: Bool { false }

    @MainActor public func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                                  diagram: DiagramHint?, explanation: String?) -> String? {
        let detail = acceptsDetail ? explanation : nil
        render(lines, perLineSeconds: perLineSeconds, diagram: diagram, explanation: detail)
        return detail
    }

    /// Captions retain the short lines; the persistent box implements the fuller detail.
    public func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?, explanation: String?) {
        render(lines, perLineSeconds: perLineSeconds, diagram: diagram)
    }

    /// Text-only sinks, such as the transient caption, retain their normal behavior.
    public func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?) {
        render(lines, perLineSeconds: perLineSeconds)
    }

    /// Convenience: show every line for the same duration. Handy for callers/tests that don't need
    /// per-line scaling.
    public func render(_ lines: [String], perLineSeconds: TimeInterval) {
        render(lines, perLineSeconds: Array(repeating: perLineSeconds, count: lines.count))
    }
}
