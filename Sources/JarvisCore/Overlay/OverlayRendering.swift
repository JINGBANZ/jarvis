import Foundation

public protocol OverlayRendering: AnyObject {
    /// Sampled at delivery, since the user can collapse the box during a request.
    @MainActor var acceptsDetail: Bool { get }
    /// The detail that reached the screen; nil if the box is hidden or nothing was left to draw.
    /// Finalizes a reply `showReplyProgress` opened instead of adding a second one.
    @MainActor func deliver(_ lines: [String], detail: ReplyDetail?) -> ReplyDetail?
    /// The reply as far as it has streamed; nil withdraws a reply that will not be delivered.
    @MainActor func showReplyProgress(_ progress: BrainReplyProgress?)
    func render(_ lines: [String])
    func render(_ lines: [String], detail: ReplyDetail?)
}

extension OverlayRendering {
    @MainActor public var acceptsDetail: Bool { false }

    @MainActor public func deliver(_ lines: [String], detail: ReplyDetail?) -> ReplyDetail? {
        let shown = acceptsDetail ? detail : nil
        render(lines, detail: shown)
        return shown?.hasContent == true ? shown : nil
    }

    @MainActor public func showReplyProgress(_ progress: BrainReplyProgress?) {}

    public func render(_ lines: [String], detail: ReplyDetail?) {
        render(lines)
    }
}
