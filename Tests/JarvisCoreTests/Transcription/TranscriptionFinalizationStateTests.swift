import Testing
@testable import JarvisCore

@Suite struct TranscriptionFinalizationStateTests {
    @Test func pcmSilenceStaysPendingUntilFinalResultsAreConsumed() throws {
        var state = TranscriptionFinalizationState()

        #expect(state.recordSpeechStarted().pendingWork == true)
        let ended = state.recordSpeechEnded(analyzerAvailable: false)
        #expect(ended.pendingWork == nil)
        #expect(ended.finalization == nil)
        #expect(state.hasPendingWork)

        let ready = state.analyzerBecameAvailable()
        let token = try #require(ready.finalization)
        #expect(state.analyzerFinalizationCompleted(
            token,
            analyzerAvailable: true).pendingWork == nil)
        #expect(state.hasPendingWork)
        #expect(state.finalResultsConsumed(
            token,
            analyzerAvailable: true).pendingWork == false)
        #expect(!state.hasPendingWork)
    }

    @Test func resultConsumptionMayPrecedeAnalyzerCompletion() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted()
        let token = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)

        #expect(state.finalResultsConsumed(
            token,
            analyzerAvailable: true).pendingWork == nil)
        #expect(state.hasPendingWork)
        let completed = state.analyzerFinalizationCompleted(
            token,
            analyzerAvailable: true)
        #expect(completed.pendingWork == false)
        #expect(completed.completedFinalization == token)
    }

    @Test func speechThatEndsDuringFinalizationRequiresANewerPass() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted()
        let first = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)

        #expect(state.recordSpeechStarted().pendingWork == nil)
        #expect(state.recordSpeechEnded(analyzerAvailable: true).finalization == nil)
        _ = state.finalResultsConsumed(first, analyzerAvailable: true)
        let completion = state.analyzerFinalizationCompleted(first, analyzerAvailable: true)
        let second = try #require(completion.finalization)
        #expect(completion.completedFinalization == first)
        #expect(completion.pendingWork == nil)
        #expect(state.hasPendingWork)

        _ = state.analyzerFinalizationCompleted(second, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(
            second,
            analyzerAvailable: true).pendingWork == false)
    }

    @Test func activeSpeechInvalidatesSettlementFromTheOlderPass() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted()
        let first = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.recordSpeechStarted()

        _ = state.finalResultsConsumed(first, analyzerAvailable: true)
        let oldCompletion = state.analyzerFinalizationCompleted(first, analyzerAvailable: true)
        #expect(oldCompletion.pendingWork == nil)
        #expect(oldCompletion.finalization == nil)
        #expect(oldCompletion.completedFinalization == first)
        #expect(state.hasPendingWork)

        let second = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.analyzerFinalizationCompleted(second, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(
            second,
            analyzerAvailable: true).pendingWork == false)
    }

    @Test func staleCompletionCannotSettleNewerWork() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted()
        let token = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.analyzerFinalizationCompleted(token, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(
            token,
            analyzerAvailable: true).pendingWork == false)

        _ = state.recordSpeechStarted()
        let stale = state.analyzerFinalizationCompleted(token, analyzerAvailable: true)
        #expect(stale.pendingWork == nil)
        #expect(state.hasPendingWork)
    }
}
