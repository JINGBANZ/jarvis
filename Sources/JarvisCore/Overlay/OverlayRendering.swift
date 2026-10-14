import Foundation

public protocol OverlayRendering: AnyObject {
    /// Whether the overlay can retain detail for the current session, regardless of collapse.
    @MainActor var acceptsDetail: Bool { get }
    /// The retained detail; nil if the session cannot accept it or nothing is left to draw.
    /// Finalizes a reply `showReplyProgress` opened instead of adding a second one.
    @MainActor func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail?
    /// The reply as far as it has streamed; nil withdraws a reply that will not be delivered.
    @MainActor func showReplyProgress(_ progress: BrainReplyProgress?)
    func render(_ hint: String)
    func render(_ hint: String, detail: ReplyDetail?)
}

extension OverlayRendering {
    @MainActor public var acceptsDetail: Bool { false }

    @MainActor public func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail? {
        let retained = acceptsDetail ? detail : nil
        render(hint, detail: retained)
        return retained?.hasContent == true ? retained : nil
    }

    @MainActor public func showReplyProgress(_ progress: BrainReplyProgress?) {}

    public func render(_ hint: String, detail: ReplyDetail?) {
        render(hint)
    }
}
