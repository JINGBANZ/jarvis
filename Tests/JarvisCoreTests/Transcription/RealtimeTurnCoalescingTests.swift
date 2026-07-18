import Testing
@testable import JarvisCore

@Suite struct RealtimeTurnCoalescingTests {
    /// Reproduces session 2026-07-18_10-30-19_02F3: each next VAD item starts before the previous
    /// item's final transcript arrives. Debounce expiry must observe the active ledger item and keep
    /// every completed fragment for one final coaching turn.
    @Test func startBeforePreviousCompletionKeepsOneSemanticTurn() throws {
        let ledger = RealtimeTranscriptionLedger()
        let pending = UtteranceBuffer()

        ledger.recordSpeechStarted(itemID: "first", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 0)
        ledger.recordSpeechStopped(itemID: "first", audioEndMilliseconds: 2_000)
        ledger.recordSpeechStarted(itemID: "second", audioStartMilliseconds: 1_950,
                                   timelineOrigin: 0)
        let first = try #require(ledger.recordCompleted(
            itemID: "first", transcript: "Violet Lantern begins.", speaker: .them))
        pending.append(try #require(first.text))

        #expect(pending.drainIfSettled(hasPendingTranscriptions: ledger.hasPendingItems)
                == .waitingForPendingTranscriptions)

        ledger.recordSpeechStopped(itemID: "second", audioEndMilliseconds: 3_000)
        ledger.recordSpeechStarted(itemID: "third", audioStartMilliseconds: 2_950,
                                   timelineOrigin: 0)
        let second = try #require(ledger.recordCompleted(
            itemID: "second", transcript: "Describe your agentic project.", speaker: .them))
        pending.append(try #require(second.text))

        #expect(pending.drainIfSettled(hasPendingTranscriptions: ledger.hasPendingItems)
                == .waitingForPendingTranscriptions)

        ledger.recordSpeechStopped(itemID: "third", audioEndMilliseconds: 4_000)
        let third = try #require(ledger.recordCompleted(
            itemID: "third", transcript: "Violet Lantern ends.", speaker: .them))
        pending.append(try #require(third.text))

        #expect(!ledger.hasPendingItems)
        #expect(pending.drainIfSettled(hasPendingTranscriptions: ledger.hasPendingItems)
                == .ready(
                    text: "Violet Lantern begins. Describe your agentic project. "
                        + "Violet Lantern ends.",
                    fragments: 3))
    }

    @Test func unusableLastItemStillReleasesEarlierCompletedFragment() throws {
        let ledger = RealtimeTranscriptionLedger()
        let pending = UtteranceBuffer()

        ledger.recordSpeechStarted(itemID: "first", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 0)
        let first = try #require(ledger.recordCompleted(
            itemID: "first", transcript: "Keep this question.", speaker: .them))
        pending.append(try #require(first.text))

        ledger.recordSpeechStarted(itemID: "noise", audioStartMilliseconds: 2_000,
                                   timelineOrigin: 0)
        ledger.recordSpeechStopped(itemID: "noise", audioEndMilliseconds: 2_200)
        #expect(pending.drainIfSettled(hasPendingTranscriptions: ledger.hasPendingItems)
                == .waitingForPendingTranscriptions)

        #expect(ledger.recordCompleted(itemID: "noise", transcript: ".", speaker: .them) == nil)
        #expect(pending.shouldResumeAfterPendingTranscriptionsSettle(
            hasPendingTranscriptions: ledger.hasPendingItems))
        #expect(pending.drainIfSettled(hasPendingTranscriptions: ledger.hasPendingItems)
                == .ready(text: "Keep this question.", fragments: 1))
    }
}
