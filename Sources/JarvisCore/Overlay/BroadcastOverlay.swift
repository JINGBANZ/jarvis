import Foundation

public final class BroadcastOverlay: OverlayRendering {
    private let sinks: [OverlayRendering]

    @MainActor public var acceptsDetail: Bool { sinks.contains { $0.acceptsDetail } }

    @MainActor public func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                                   detail: ReplyDetail?) -> ReplyDetail? {
        var delivered: ReplyDetail?
        for sink in sinks {
            if let shown = sink.deliver(lines, perLineSeconds: perLineSeconds, detail: detail) {
                delivered = shown
            }
        }
        return delivered
    }

    /// Forwarded explicitly: the protocol's default would swallow every update in production.
    @MainActor public func showReplyProgress(_ progress: BrainReplyProgress?, perLineSeconds: [TimeInterval]) {
        for sink in sinks {
            sink.showReplyProgress(progress, perLineSeconds: perLineSeconds)
        }
    }

    public init(_ sinks: [OverlayRendering]) {
        self.sinks = sinks
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval],
                                   detail: ReplyDetail?) {
        for sink in sinks {
            sink.render(lines, perLineSeconds: perLineSeconds, detail: detail)
        }
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        for sink in sinks {
            sink.render(lines, perLineSeconds: perLineSeconds)
        }
    }
}
