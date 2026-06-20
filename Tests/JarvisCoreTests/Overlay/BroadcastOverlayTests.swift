import Testing
import Foundation
@testable import JarvisCore

/// Records every `render` call so a test can assert the broadcast reached this sink.
private final class RecordingSink: OverlayRendering, @unchecked Sendable {
    var rendered: [[String]] = []
    var renderedSeconds: [[TimeInterval]] = []
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        rendered.append(lines)
        renderedSeconds.append(perLineSeconds)
    }
}

@Suite struct BroadcastOverlayTests {

    @Test func fansEachRenderOutToEverySink() {
        let a = RecordingSink(), b = RecordingSink()
        let broadcast = BroadcastOverlay([a, b])

        broadcast.render(["one", "two"], perLineSeconds: [1.0, 2.0])

        #expect(a.rendered == [["one", "two"]])
        #expect(b.rendered == [["one", "two"]])
        #expect(a.renderedSeconds == [[1.0, 2.0]])
        #expect(b.renderedSeconds == [[1.0, 2.0]])
    }

    @Test func preservesCallOrderAcrossMultipleRenders() {
        let sink = RecordingSink()
        let broadcast = BroadcastOverlay([sink])

        broadcast.render(["first"], perLineSeconds: [0.5])
        broadcast.render(["second"], perLineSeconds: [0.5])

        #expect(sink.rendered == [["first"], ["second"]])
    }

    @Test func withNoSinksIsANoOp() {
        // Empty fan-out must not crash — a degenerate but valid configuration.
        BroadcastOverlay([]).render(["x"], perLineSeconds: [1.0])
    }
}
