import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionFinalizationStateTests {
    @Test func pcmSilenceStaysPendingUntilFinalResultsAreConsumed() throws {
        var state = TranscriptionFinalizationState()

        let opened = try #require(state.recordSpeechStarted(at: 4).work)
        #expect(opened == .pending(since: 4))
        #expect(!opened.permitsCoaching(through: 5))
        let ended = state.recordSpeechEnded(analyzerAvailable: false)
        #expect(ended.work == nil)
        #expect(ended.finalization == nil)
        #expect(state.hasPendingWork)

        let ready = state.analyzerBecameAvailable()
        let token = try #require(ready.finalization)
        #expect(state.analyzerFinalizationCompleted(
            token,
            analyzerAvailable: true).work == nil)
        #expect(state.hasPendingWork)
        #expect(state.finalResultsConsumed(
            token,
            analyzerAvailable: true).work == .settled)
        #expect(!state.hasPendingWork)
    }

    @Test func aPhraseFinalizedMidSentenceWaitsForTheSentenceToSettle() throws {
        var state = TranscriptionFinalizationState()
        let work = try #require(state.recordSpeechStarted(at: 4).work)

        // A final for the sentence's first phrase is stamped at the sentence's own start.
        #expect(!work.permitsCoaching(through: 4))
        #expect(work.permitsCoaching(through: 3))
    }

    @Test func laterSpeechDoesNotMoveAnUnsettledPendingStart() {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted(at: 4)
        _ = state.recordSpeechEnded(analyzerAvailable: false)

        #expect(state.recordSpeechStarted(at: 9).work == nil)
    }

    @Test func aSettledEpisodeOpensTheNextWindowAtItsOwnOnset() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted(at: 4)
        let token = try #require(state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.analyzerFinalizationCompleted(token, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(token, analyzerAvailable: true).work == .settled)

        #expect(state.recordSpeechStarted(at: 9).work == .pending(since: 9))
    }

    @Test func speechWithoutATimedOnsetStaysUnknown() throws {
        var state = TranscriptionFinalizationState()
        let work = try #require(state.recordSpeechStarted(at: .nan).work)
        #expect(work == .pending(since: nil))
        #expect(!work.permitsCoaching(through: 1))
    }

    @Test func resultConsumptionMayPrecedeAnalyzerCompletion() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted(at: 1)
        let token = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)

        #expect(state.finalResultsConsumed(
            token,
            analyzerAvailable: true).work == nil)
        #expect(state.hasPendingWork)
        let completed = state.analyzerFinalizationCompleted(
            token,
            analyzerAvailable: true)
        #expect(completed.work == .settled)
        #expect(completed.completedFinalization == token)
    }

    @Test func speechThatEndsDuringFinalizationRequiresANewerPass() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted(at: 1)
        let first = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)

        #expect(state.recordSpeechStarted(at: 2).work == nil)
        #expect(state.recordSpeechEnded(analyzerAvailable: true).finalization == nil)
        _ = state.finalResultsConsumed(first, analyzerAvailable: true)
        let completion = state.analyzerFinalizationCompleted(first, analyzerAvailable: true)
        let second = try #require(completion.finalization)
        #expect(completion.completedFinalization == first)
        #expect(completion.work == nil)
        #expect(state.hasPendingWork)

        _ = state.analyzerFinalizationCompleted(second, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(
            second,
            analyzerAvailable: true).work == .settled)
    }

    @Test func activeSpeechInvalidatesSettlementFromTheOlderPass() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted(at: 1)
        let first = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.recordSpeechStarted(at: 2)

        _ = state.finalResultsConsumed(first, analyzerAvailable: true)
        let oldCompletion = state.analyzerFinalizationCompleted(first, analyzerAvailable: true)
        #expect(oldCompletion.work == nil)
        #expect(oldCompletion.finalization == nil)
        #expect(oldCompletion.completedFinalization == first)
        #expect(state.hasPendingWork)

        let second = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.analyzerFinalizationCompleted(second, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(
            second,
            analyzerAvailable: true).work == .settled)
    }

    @Test func staleCompletionCannotSettleNewerWork() throws {
        var state = TranscriptionFinalizationState()
        _ = state.recordSpeechStarted(at: 1)
        let token = try #require(
            state.recordSpeechEnded(analyzerAvailable: true).finalization)
        _ = state.analyzerFinalizationCompleted(token, analyzerAvailable: true)
        #expect(state.finalResultsConsumed(
            token,
            analyzerAvailable: true).work == .settled)

        _ = state.recordSpeechStarted(at: 5)
        let stale = state.analyzerFinalizationCompleted(token, analyzerAvailable: true)
        #expect(stale.work == nil)
        #expect(state.hasPendingWork)
    }
}
