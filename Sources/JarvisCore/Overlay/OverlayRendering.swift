import Foundation

public protocol OverlayRendering: AnyObject {
    /// Sampled at delivery, since the user can hide the persistent surface during a request.
    @MainActor var acceptsDetail: Bool { get }
    /// The detail that reached the screen; nil if the box is hidden or nothing was left to draw.
    @MainActor func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                            detail: ReplyDetail?) -> ReplyDetail?
    /// `perLineSeconds` should align with `lines`; a shorter array truncates safely.
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

    public func render(_ lines: [String], perLineSeconds: [TimeInterval], detail: ReplyDetail?) {
        render(lines, perLineSeconds: perLineSeconds)
    }

    public func render(_ lines: [String], perLineSeconds: TimeInterval) {
        render(lines, perLineSeconds: Array(repeating: perLineSeconds, count: lines.count))
    }
}
