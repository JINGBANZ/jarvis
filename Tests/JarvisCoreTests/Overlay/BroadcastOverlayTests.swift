import Testing
import Foundation
@testable import JarvisCore

/// @unchecked: render runs synchronously on the test's own task.
private final class RecordingSink: OverlayRendering, @unchecked Sendable {
    var rendered: [[String]] = []
    var renderedSeconds: [[TimeInterval]] = []
    var progress: [BrainReplyProgress?] = []
    var progressSeconds: [[TimeInterval]] = []
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        rendered.append(lines)
        renderedSeconds.append(perLineSeconds)
    }
    @MainActor func showReplyProgress(_ progress: BrainReplyProgress?, perLineSeconds: [TimeInterval]) {
        self.progress.append(progress)
        progressSeconds.append(perLineSeconds)
    }
}

@Suite struct BroadcastOverlayTests {

    @MainActor @Test func forwardsReplyProgressAndWithdrawalToEverySink() {
        let a = RecordingSink(), b = RecordingSink()
        let broadcast = BroadcastOverlay([a, b])
        let snapshot = BrainReplyProgress(closedLines: ["one"], openLine: "tw", linesComplete: false, detailMarkdown: nil)

        broadcast.showReplyProgress(snapshot, perLineSeconds: [2.0])
        broadcast.showReplyProgress(nil, perLineSeconds: [])

        #expect(a.progress == [snapshot, nil])
        #expect(b.progress == [snapshot, nil])
        #expect(a.progressSeconds == [[2.0], []])
    }

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
        BroadcastOverlay([]).render(["x"], perLineSeconds: [1.0])
    }
}
