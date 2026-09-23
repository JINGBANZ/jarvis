import Foundation

public protocol OverlayRendering: AnyObject {
    /// Sampled at delivery, since the user can collapse the box during a request.
    @MainActor var acceptsDetail: Bool { get }
    /// The detail that reached the screen; nil if the box is hidden or nothing was left to draw.
    @MainActor func deliver(_ lines: [String], detail: ReplyDetail?) -> ReplyDetail?
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

    public func render(_ lines: [String], detail: ReplyDetail?) {
        render(lines)
    }
}
