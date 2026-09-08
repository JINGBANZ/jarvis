import Foundation

/// Fans a single `render(_:perLineSeconds:)` out to several overlay sinks in order, so `CoachDriver`
/// keeps talking to ONE `OverlayRendering` while each spoken tip reaches both the Overlay Caption and
/// the persistent Overlay Box. Adding a sink needs no change to the driver or the brain.
public final class BroadcastOverlay: OverlayRendering {
    private let sinks: [OverlayRendering]

    public init(_ sinks: [OverlayRendering]) {
        self.sinks = sinks
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
