import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptPaneContentTests {
    private typealias Row = TranscriptPaneContent.Row

    @Test func linesAppearInSpokenOrderNotArrivalOrder() {
        let content = TranscriptPaneContent.make(
            lines: [
                .init(speaker: .me, text: "Sure.", at: 9),
                .init(speaker: .them, text: "Can you hear me?", at: 4),
            ],
            firstIndex: 0, handledCount: 0, live: [:], now: 10)

        #expect(content.rows.map(\.text) == ["Can you hear me?", "Sure."])
        #expect(content.rows.map(\.speaker) == [.them, .me])
    }

    @Test func linesBeforeTheHandledBoundaryAreHandled() {
        let content = TranscriptPaneContent.make(
            lines: [
                .init(speaker: .them, text: "Design a cache.", at: 1),
                .init(speaker: .me, text: "What size?", at: 3),
                .init(speaker: .them, text: "A few gigabytes.", at: 5),
            ],
            firstIndex: 10, handledCount: 12, live: [:], now: 6)

        #expect(content.rows.map(\.state) == [.handled, .handled, .unhandled])
    }

    @Test func handlingFollowsInsertionIndexEvenWhenALateLineSortsEarlier() {
        // Index 1 finalized late but was spoken first; only index 0 has been handled.
        let content = TranscriptPaneContent.make(
            lines: [
                .init(speaker: .me, text: "I'd use LRU.", at: 8),
                .init(speaker: .them, text: "Any eviction policy?", at: 6),
            ],
            firstIndex: 0, handledCount: 1, live: [:], now: 9)

        #expect(content.rows == [
            Row(speaker: .them, text: "Any eviction policy?", state: .unhandled),
            Row(speaker: .me, text: "I'd use LRU.", state: .handled),
        ])
    }

    @Test func speechInProgressShowsHowLongItHasRun() {
        let content = TranscriptPaneContent.make(
            lines: [], firstIndex: 0, handledCount: 0,
            live: [.them: .speaking(since: 20.4)], now: 32.9)

        #expect(content.rows == [Row(speaker: .them, text: "speaking… 12s", state: .inProgress)])
    }

    @Test func speechInProgressWithAnUnknownStartShowsNoDuration() {
        let content = TranscriptPaneContent.make(
            lines: [], firstIndex: 0, handledCount: 0,
            live: [.me: .speaking(since: nil)], now: 5)

        #expect(content.rows == [Row(speaker: .me, text: "speaking…", state: .inProgress)])
    }

    @Test func interimTextIsShownAsTheInProgressRowAfterTheFinalizedLines() {
        let content = TranscriptPaneContent.make(
            lines: [.init(speaker: .me, text: "Okay.", at: 1)],
            firstIndex: 0, handledCount: 1,
            live: [.me: .speaking(since: 2), .them: .interim("let's talk about ind")], now: 4)

        #expect(content.rows == [
            Row(speaker: .me, text: "Okay.", state: .handled),
            Row(speaker: .them, text: "let's talk about ind", state: .inProgress),
            Row(speaker: .me, text: "speaking… 2s", state: .inProgress),
        ])
    }

    @Test func blankInterimTextFallsBackToNothing() {
        let content = TranscriptPaneContent.make(
            lines: [], firstIndex: 0, handledCount: 0,
            live: [.them: .interim("  ")], now: 4)

        #expect(content.rows.isEmpty)
    }
}
