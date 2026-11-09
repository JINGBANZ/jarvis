import Testing
@testable import JarvisCore

@Suite struct RealtimeReconnectTranscriptionRecoveryTests {
    @Test func replayBlocksTurnUntilEveryInterruptedReplacementSettles() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(interruptedItems: [fallback("one"), fallback("two")],
                       duplicateRiskItemCount: 0, replayAvailable: true)

        #expect(recovery.blocksCoaching)
        #expect(recovery.markReplacementReady().isEmpty)
        #expect(recovery.resolveReplacement(hasUsableText: true) == .appendReplacement)
        #expect(recovery.blocksCoaching)
        #expect(recovery.resolveReplacement(hasUsableText: true) == .appendReplacement)
        #expect(!recovery.blocksCoaching)
    }

    @Test func replaySuppressesAlreadyDeliveredItemBeforeInterruptedReplacement() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(interruptedItems: [fallback("partial")], duplicateRiskItemCount: 1,
                       replayAvailable: true)
        _ = recovery.markReplacementReady()

        #expect(recovery.resolveReplacement(hasUsableText: true)
                == .suppressAlreadyDeliveredReplay)
        #expect(recovery.blocksCoaching)
        #expect(recovery.resolveReplacement(hasUsableText: true) == .appendReplacement)
        #expect(!recovery.blocksCoaching)
    }

    @Test func missingReplacementTextUsesRetainedDeltaFallback() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        let partial = fallback("retained partial")
        recovery.begin(interruptedItems: [partial], duplicateRiskItemCount: 0,
                       replayAvailable: true)
        _ = recovery.markReplacementReady()

        #expect(recovery.resolveReplacement(hasUsableText: false) == .useFallback(partial))
        #expect(!recovery.blocksCoaching)
    }

    @Test func replacementCompletionWaitsForTimingBeforeConsumingFallback() throws {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "interrupted", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 0)
        ledger.recordSpeechStopped(itemID: "interrupted", audioEndMilliseconds: 2_000)
        ledger.recordDelta(itemID: "interrupted", delta: "retained partial")
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(interruptedItems: ledger.resolveAllInterruptedItems(speaker: .me),
                       duplicateRiskItemCount: 0, replayAvailable: true)
        _ = recovery.markReplacementReady()
        ledger.clear()

        ledger.recordSpeechStarted(itemID: "replacement", audioStartMilliseconds: 1_000,
                                   timelineOrigin: 0)
        #expect(ledger.recordCompleted(itemID: "replacement", transcript: "actual final",
                                       speaker: .me) == nil)
        #expect(ledger.isPending(itemID: "replacement"))
        #expect(!ledger.isPending(itemID: "interrupted"))
        #expect(recovery.unresolvedItemCount == 1)
        #expect(recovery.blocksCoaching)

        ledger.recordSpeechStopped(itemID: "replacement", audioEndMilliseconds: 2_000)
        let final = try #require(ledger.takeCompletedItem(itemID: "replacement"))
        #expect(!ledger.isPending(itemID: "replacement"))
        #expect(final.text == "actual final")
        #expect(recovery.resolveReplacement(hasUsableText: final.text != nil) == .appendReplacement)
        #expect(!recovery.blocksCoaching)
        #expect(recovery.timeout().isEmpty)
        #expect(ledger.takeCompletedItem(itemID: "replacement") == nil)
    }

    @Test func filteredReplacementConsumedAfterTimingSettlesExactlyOneFallback() {
        let ledger = RealtimeTranscriptionLedger()
        var recovery = RealtimeReconnectTranscriptionRecovery()
        let first = fallback("first partial"), second = fallback("second partial")
        recovery.begin(interruptedItems: [first, second], duplicateRiskItemCount: 0, replayAvailable: true)
        _ = recovery.markReplacementReady()
        ledger.recordSpeechStarted(itemID: "filtered", audioStartMilliseconds: 1_000, timelineOrigin: 0)
        #expect(ledger.recordCompleted(itemID: "filtered", transcript: "Thank you.", speaker: .me) == nil)
        #expect(ledger.isPending(itemID: "filtered"))
        #expect(recovery.unresolvedItemCount == 2)

        ledger.recordSpeechStopped(itemID: "filtered", audioEndMilliseconds: 1_100)
        let wasPending = ledger.isPending(itemID: "filtered")
        let item = ledger.takeCompletedItem(itemID: "filtered")
        #expect(wasPending)
        #expect(!ledger.isPending(itemID: "filtered"))
        #expect(item == nil)
        #expect(recovery.resolveReplacement(hasUsableText: item?.text != nil) == .useFallback(first))
        #expect(recovery.unresolvedItemCount == 1)
        #expect(ledger.resolveStoppedItemTimeout(itemID: "filtered", speaker: .me) == nil)
        #expect(!ledger.isPending(itemID: "filtered"))
        #expect(recovery.resolveReplacement(hasUsableText: true) == .appendReplacement)
        #expect(recovery.timeout().isEmpty)
    }

    @Test func coverageLossOrNoReplayImmediatelySalvagesInterruptedItems() {
        var beforeReady = RealtimeReconnectTranscriptionRecovery()
        let partial = fallback("partial")
        beforeReady.begin(interruptedItems: [partial], duplicateRiskItemCount: 1,
                          replayAvailable: true)
        #expect(beforeReady.recordCoverageLoss().isEmpty)
        #expect(beforeReady.markReplacementReady() == [partial])
        #expect(!beforeReady.blocksCoaching)

        var noReplay = RealtimeReconnectTranscriptionRecovery()
        noReplay.begin(interruptedItems: [partial], duplicateRiskItemCount: 1,
                       replayAvailable: false)
        #expect(noReplay.blocksCoaching)
        #expect(noReplay.markReplacementReady() == [partial])
        #expect(!noReplay.blocksCoaching)
    }

    @Test func timeoutSalvagesOnlyInterruptedItemsAndClearsDuplicateRisk() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        let partial = fallback("partial")
        recovery.begin(interruptedItems: [partial], duplicateRiskItemCount: 2,
                       replayAvailable: true)
        _ = recovery.markReplacementReady()

        #expect(recovery.timeout() == [partial])
        #expect(!recovery.blocksCoaching)
    }

    @Test func untrackedReconnectAudioBlocksUntilTheBoundedRecoveryDeadline() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(
            interruptedItems: [],
            duplicateRiskItemCount: 0,
            replayAvailable: true,
            hasUntrackedReplayAudio: true)

        #expect(recovery.blocksCoaching)
        #expect(recovery.markReplacementReady().isEmpty)
        #expect(recovery.blocksCoaching)
        #expect(recovery.timeout().isEmpty)
        #expect(!recovery.blocksCoaching)
    }

    @Test func audioCapturedAfterRecoveryBeginsAddsAnUntrackedBarrier() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        let partial = fallback("known item")
        recovery.begin(
            interruptedItems: [partial],
            duplicateRiskItemCount: 0,
            replayAvailable: true)
        recovery.recordUntrackedReplayAudio()
        _ = recovery.markReplacementReady()

        #expect(recovery.resolveReplacement(hasUsableText: true) == .appendReplacement)
        #expect(recovery.blocksCoaching)
        #expect(recovery.timeout().isEmpty)
        #expect(!recovery.blocksCoaching)
    }

    @Test func coverageLossReleasesUntrackedReplayAudioAfterReplacementIsReady() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(
            interruptedItems: [],
            duplicateRiskItemCount: 0,
            replayAvailable: true,
            hasUntrackedReplayAudio: true)
        _ = recovery.markReplacementReady()

        #expect(recovery.recordCoverageLoss().isEmpty)
        #expect(!recovery.blocksCoaching)
    }

    @Test func consecutiveReconnectRetainsLaterPartialUntilCoverageLoss() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(
            interruptedItems: [],
            duplicateRiskItemCount: 0,
            replayAvailable: true,
            hasUntrackedReplayAudio: true)
        _ = recovery.markReplacementReady()

        let laterPartial = fallback("replacement partial")
        recovery.begin(
            interruptedItems: [laterPartial],
            duplicateRiskItemCount: 0,
            replayAvailable: true)
        #expect(recovery.blocksCoaching)
        #expect(recovery.markReplacementReady().isEmpty)

        #expect(recovery.recordCoverageLoss() == [laterPartial])
        #expect(!recovery.blocksCoaching)
    }

    @Test func consecutiveReconnectRetainsLaterPartialUntilRecoveryDeadline() {
        var recovery = RealtimeReconnectTranscriptionRecovery()
        recovery.begin(
            interruptedItems: [],
            duplicateRiskItemCount: 0,
            replayAvailable: true,
            hasUntrackedReplayAudio: true)
        _ = recovery.markReplacementReady()

        let laterPartial = fallback("replacement partial")
        recovery.begin(
            interruptedItems: [laterPartial],
            duplicateRiskItemCount: 0,
            replayAvailable: true)
        _ = recovery.markReplacementReady()

        #expect(recovery.timeout() == [laterPartial])
        #expect(!recovery.blocksCoaching)
    }

    private func fallback(_ text: String) -> RealtimeTranscriptionLedger.FinalizedItem {
        .init(itemID: text, text: text, spokenAt: 1, spokenEndAt: nil,
              recoveredFromDeltas: true, isTranscriptUnavailable: false)
    }
}
