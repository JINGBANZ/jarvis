import Foundation

/// Fans a single `render(_:perLineSeconds:)` out to several overlay sinks in order, so `CoachDriver`
/// keeps talking to ONE `OverlayRendering` while each spoken tip reaches both the Overlay Caption and
/// the persistent Overlay Box. Adding a sink needs no change to the driver or the brain.
public final class BroadcastOverlay: OverlayRendering {
    private let sinks: [OverlayRendering]

    @MainActor public var acceptsDetail: Bool { sinks.contains { $0.acceptsDetail } }

    @MainActor public func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                                  diagram: DiagramHint?, explanation: String?) -> String? {
        var delivered: String?
        for sink in sinks {
            if let detail = sink.deliver(lines, perLineSeconds: perLineSeconds, diagram: diagram, explanation: explanation) {
                delivered = detail
            }
        }
        return delivered
    }

    public init(_ sinks: [OverlayRendering]) {
        self.sinks = sinks
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?, explanation: String?) {
        for sink in sinks {
            sink.render(lines, perLineSeconds: perLineSeconds, diagram: diagram, explanation: explanation)
        }
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?) {
        for sink in sinks {
            sink.render(lines, perLineSeconds: perLineSeconds, diagram: diagram)
        }
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        for sink in sinks {
            sink.render(lines, perLineSeconds: perLineSeconds)
        }
    }
}
