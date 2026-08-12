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
