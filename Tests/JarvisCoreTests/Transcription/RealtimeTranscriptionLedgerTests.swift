import Testing
@testable import JarvisCore

@Suite struct RealtimeTranscriptionLedgerTests {
    @Test func interleavedItemsKeepTheirOwnDeltasAndAudioStartTimes() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "first", audioStartMilliseconds: 1_250, timelineOrigin: 10)
        ledger.recordSpeechStarted(itemID: "second", audioStartMilliseconds: 3_000, timelineOrigin: 10)
        ledger.recordDelta(itemID: "first", delta: "first ")
        ledger.recordDelta(itemID: "second", delta: "second")
        ledger.recordDelta(itemID: "first", delta: "answer")

        let second = try #require(ledger.recordCompleted(itemID: "second", transcript: "second final",
                                                        speaker: .them))
        let first = try #require(ledger.recordCompleted(itemID: "first", transcript: "first final",
                                                       speaker: .them))
        #expect(second.text == "second final")
        #expect(second.spokenAt == 13)
        #expect(second.spokenEndAt == nil)
        #expect(first.text == "first final")
        #expect(first.spokenAt == 11.25)
    }

    @Test func failedItemSalvagesAccumulatedDeltas() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "item", audioStartMilliseconds: 500, timelineOrigin: 4)
        ledger.recordDelta(itemID: "item", delta: "What is ")
        ledger.recordDelta(itemID: "item", delta: "a semaphore?")

        let result = try #require(ledger.recordFailed(itemID: "item", speaker: .them))
        #expect(result.text == "What is a semaphore?")
        #expect(result.spokenAt == 4.5)
        #expect(result.recoveredFromDeltas)
        #expect(!result.isContextGap)
    }

    @Test func failedItemWithoutUsableTextEmitsExplicitContextGap() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "item", audioStartMilliseconds: 250, timelineOrigin: 7)
        ledger.recordDelta(itemID: "item", delta: "...")

        let result = try #require(ledger.recordFailed(itemID: "item", speaker: .them))
        #expect(result.text == RealtimeTranscriptionLedger.contextGapMarker)
        #expect(result.spokenAt == 7.25)
        #expect(!result.recoveredFromDeltas)
        #expect(result.isContextGap)
    }

    @Test func stoppedWithoutTerminalEventSalvagesDeltasAtDeadline() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "item", audioStartMilliseconds: 8_000, timelineOrigin: 1)
        ledger.recordDelta(itemID: "item", delta: "partial question")
        #expect(ledger.recordSpeechStopped(itemID: "item"))

        let result = try #require(ledger.resolveStoppedItemTimeout(itemID: "item", speaker: .them))
        #expect(result.text == "partial question")
        #expect(result.spokenAt == 9)
        #expect(result.recoveredFromDeltas)
    }

    @Test func stoppedTimeoutSuppressesShortOrUntimedEmptyVADBlips() throws {
        let short = RealtimeTranscriptionLedger()
        short.recordSpeechStarted(itemID: "short", audioStartMilliseconds: 1_000,
                                  timelineOrigin: 0)
        short.recordSpeechStopped(itemID: "short", audioEndMilliseconds: 1_200)
        #expect(short.resolveStoppedItemTimeout(itemID: "short", speaker: .me) == nil)
        #expect(!short.hasPendingItems)
        #expect(short.recordCompleted(itemID: "short", transcript: "late", speaker: .me) == nil)

        let untimed = RealtimeTranscriptionLedger()
        untimed.recordSpeechStopped(itemID: "untimed")
        #expect(untimed.resolveStoppedItemTimeout(itemID: "untimed", speaker: .them) == nil)
        #expect(!untimed.hasPendingItems)

        let speech = RealtimeTranscriptionLedger()
        speech.recordSpeechStarted(itemID: "speech", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 0)
        speech.recordSpeechStopped(itemID: "speech", audioEndMilliseconds: 1_750)
        let gap = try #require(
            speech.resolveStoppedItemTimeout(itemID: "speech", speaker: .them))
        #expect(gap.isContextGap)
    }

    @Test func timeoutOnlyFinalizesStoppedItemsAndLateTerminalIsIgnored() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "item", audioStartMilliseconds: 0, timelineOrigin: 0)
        ledger.recordDelta(itemID: "item", delta: "still speaking")
        #expect(ledger.hasPendingItems)
        #expect(ledger.resolveStoppedItemTimeout(itemID: "item", speaker: .me) == nil)

        ledger.recordSpeechStopped(itemID: "item")
        #expect(ledger.hasPendingItems)
        let result = try #require(ledger.resolveStoppedItemTimeout(itemID: "item", speaker: .me))
        #expect(result.text == "still speaking")
        #expect(!ledger.hasPendingItems)
        #expect(ledger.recordCompleted(itemID: "item", transcript: "still speaking, finalized",
                                      speaker: .me) == nil)
        #expect(ledger.recordFailed(itemID: "item", speaker: .me) == nil)
    }

    @Test func emptyCompletedTextUsesDeltasButNoiseCompletionStaysSilent() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordDelta(itemID: "partial", delta: "usable partial")
        let partial = try #require(ledger.recordCompleted(itemID: "partial", transcript: "",
                                                         speaker: .me))
        #expect(partial.text == "usable partial")
        #expect(partial.recoveredFromDeltas)

        ledger.recordDelta(itemID: "noise", delta: ".")
        #expect(ledger.recordCompleted(itemID: "noise", transcript: ".", speaker: .me) == nil)
    }

    @Test func longDetectedSpeechWithEmptyCompletionEmitsContextGap() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "question", audioStartMilliseconds: 2_000,
                                   timelineOrigin: 10)
        ledger.recordSpeechStopped(itemID: "question", audioEndMilliseconds: 4_500)

        let result = try #require(ledger.recordCompleted(itemID: "question", transcript: "",
                                                        speaker: .them))
        #expect(result.text == RealtimeTranscriptionLedger.contextGapMarker)
        #expect(result.spokenAt == 12)
        #expect(result.isContextGap)

        let shortNoise = RealtimeTranscriptionLedger()
        shortNoise.recordSpeechStarted(itemID: "noise", audioStartMilliseconds: 1_000,
                                       timelineOrigin: 0)
        shortNoise.recordSpeechStopped(itemID: "noise", audioEndMilliseconds: 1_200)
        #expect(shortNoise.recordCompleted(itemID: "noise", transcript: ".", speaker: .me) == nil)
    }

    @Test func activeTimeoutAndSocketFailureCannotLeavePendingSpeechBehind() throws {
        let activeTimeout = RealtimeTranscriptionLedger()
        activeTimeout.recordSpeechStarted(itemID: "active", audioStartMilliseconds: 5_000,
                                          timelineOrigin: 10)
        activeTimeout.recordDelta(itemID: "active", delta: "partial answer")
        let timedOut = try #require(activeTimeout.resolveActiveItemTimeout(itemID: "active",
                                                                          speaker: .me))
        #expect(timedOut.text == "partial answer")
        #expect(!activeTimeout.hasPendingItems)

        let disconnected = RealtimeTranscriptionLedger()
        disconnected.recordSpeechStarted(itemID: "first", audioStartMilliseconds: 2_000,
                                          timelineOrigin: 0)
        disconnected.recordDelta(itemID: "first", delta: "first partial")
        disconnected.recordSpeechStarted(itemID: "second", audioStartMilliseconds: 3_000,
                                          timelineOrigin: 0)
        let recovered = disconnected.resolveAllInterruptedItems(speaker: .them)
        #expect(recovered.map(\.itemID) == ["first", "second"])
        #expect(recovered[0].text == "first partial")
        #expect(recovered[1].isContextGap)
        #expect(!disconnected.hasPendingItems)
    }

    @Test func replayDiscardBoundaryWaitsForOutOfOrderEarlierItem() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "first", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 10)
        ledger.recordSpeechStopped(itemID: "first", audioEndMilliseconds: 3_000)
        ledger.recordSpeechStarted(itemID: "second", audioStartMilliseconds: 4_000,
                                   timelineOrigin: 10)
        ledger.recordSpeechStopped(itemID: "second", audioEndMilliseconds: 6_000)

        #expect(ledger.safeReplayDiscardTime == 11)
        _ = try #require(ledger.recordCompleted(itemID: "second", transcript: "second",
                                                speaker: .them))
        #expect(ledger.safeReplayDiscardTime == 11) // first is still unresolved

        let first = try #require(ledger.recordCompleted(itemID: "first", transcript: "first",
                                                        speaker: .them))
        #expect(first.spokenEndAt == 13)
        #expect(ledger.safeReplayDiscardTime == 16) // advances through both terminal items
    }

    @Test func unknownPendingItemBlocksReplayDiscardAndClearResetsBoundary() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "known", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 5)
        ledger.recordSpeechStopped(itemID: "known", audioEndMilliseconds: 2_000)
        _ = try #require(ledger.recordCompleted(itemID: "known", transcript: "done", speaker: .me))
        #expect(ledger.safeReplayDiscardTime == 7)

        ledger.recordDelta(itemID: "unknown", delta: "partial")
        #expect(ledger.safeReplayDiscardTime == nil)
        ledger.clear()
        #expect(ledger.safeReplayDiscardTime == nil)
        #expect(ledger.pendingItemCount == 0)
    }
}
