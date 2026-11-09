import Testing
import Foundation
@testable import JarvisCore

@Suite struct DeepgramUtteranceAssemblerTests {
    private func interim(_ text: String, start: TimeInterval, end: TimeInterval) -> DeepgramLiveSession.Event {
        .results(.init(transcript: text, isFinal: false, speechFinal: false, start: start, end: end))
    }

    private func final(
        _ text: String, start: TimeInterval, end: TimeInterval, lastWordEnd: TimeInterval? = nil,
        speechFinal: Bool = false
    ) -> DeepgramLiveSession.Event {
        .results(.init(transcript: text, isFinal: true, speechFinal: speechFinal,
                       start: start, end: end, lastWordEnd: lastWordEnd ?? (text.isEmpty ? nil : end)))
    }

    private static func liveAssembler() -> DeepgramUtteranceAssembler {
        var assembler = DeepgramUtteranceAssembler()
        assembler.reset(socket: 1)
        return assembler
    }

    @Test func startsWithNothingUnresolved() {
        #expect(!Self.liveAssembler().hasUnresolvedSpeech)
    }

    @Test func endpointingClosesEverySettledSegmentAsOneUtterance() {
        var assembler = Self.liveAssembler()
        #expect(assembler.receive(interim("Tell me", start: 0, end: 1)).isEmpty)
        #expect(assembler.hasUnresolvedSpeech)
        #expect(assembler.receive(final("Tell me about a time.", start: 0, end: 4, lastWordEnd: 3.8)).isEmpty)
        #expect(assembler.hasUnresolvedSpeech)
        #expect(assembler.receive(final("I would check the logs.", start: 4, end: 6, speechFinal: true))
            == ["Tell me about a time.", "I would check the logs."])
        #expect(assembler.hasUnresolvedSpeech, "the utterance is unresolved until it is published")
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    /// The review's first sequence: a finalized segment, newer speech, then an `UtteranceEnd` for the
    /// earlier gap. Only the earlier words close; the newer speech stays pending.
    @Test func anEarlierUtteranceEndLeavesNewerSpeechUnresolved() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("First thought.", start: 0, end: 2, lastWordEnd: 1.6))
        _ = assembler.receive(interim("And then", start: 2, end: 3))
        #expect(assembler.receive(.utteranceEnd(lastWordEnd: 1.6)) == ["First thought."])
        assembler.finishPublishing()
        #expect(assembler.hasUnresolvedSpeech, "the newer interim words are not finalized yet")

        #expect(assembler.receive(final("And then a second.", start: 2, end: 4, speechFinal: true))
            == ["And then a second."])
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    @Test func anEarlierUtteranceEndKeepsLaterSettledSegmentsForTheirOwnUtterance() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("First.", start: 0, end: 2, lastWordEnd: 1.5))
        _ = assembler.receive(final("Second", start: 2, end: 3.5, lastWordEnd: 3.4))
        #expect(assembler.receive(.utteranceEnd(lastWordEnd: 1.5)) == ["First."])
        assembler.finishPublishing()
        #expect(assembler.hasUnresolvedSpeech)
        #expect(assembler.receive(.utteranceEnd(lastWordEnd: 3.4)) == ["Second"])
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    @Test func speechThatStartsAfterTheLastFinalStaysUnresolved() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("Done.", start: 0, end: 2, speechFinal: true))
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
        _ = assembler.receive(.speechStarted(at: 2.4))
        #expect(assembler.hasUnresolvedSpeech)
        _ = assembler.receive(final("", start: 2, end: 3.5, speechFinal: true))
        #expect(!assembler.hasUnresolvedSpeech, "a wordless final covering the onset resolves it")
    }

    @Test func speechStartedInsideAFinalizedSpanIsResolved() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(.speechStarted(at: 0.2))
        _ = assembler.receive(final("Hi.", start: 0, end: 1, speechFinal: true))
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    @Test func emptyInterimsAreNotSpeech() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(interim("", start: 0, end: 1))
        #expect(!assembler.hasUnresolvedSpeech)
    }

    @Test func aWordlessEndpointPublishesNothing() {
        var assembler = Self.liveAssembler()
        #expect(assembler.receive(final("", start: 0, end: 1, speechFinal: true)).isEmpty)
        #expect(!assembler.hasUnresolvedSpeech)
    }

    @Test func closeAllSalvagesSettledWordsAndForgetsUnfinalizedSpeech() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("Half a", start: 0, end: 1))
        _ = assembler.receive(interim("thought", start: 1, end: 2))
        #expect(assembler.closeAll() == ["Half a"])
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    /// A new socket restarts Deepgram's clock, so the old boundary must not hide new speech.
    @Test func resetForgetsTheOldSocketsClock() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("Earlier.", start: 0, end: 50, speechFinal: true))
        assembler.finishPublishing()
        assembler.reset(socket: 2)
        _ = assembler.receive(.speechStarted(at: 0.5), socket: 2)
        #expect(assembler.hasUnresolvedSpeech)
    }

    @Test func resetLeavesAnInFlightPublicationUnresolved() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("Bye.", start: 0, end: 1, speechFinal: true))
        assembler.reset(socket: 2)
        #expect(assembler.hasUnresolvedSpeech)
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    /// The second review's first sequence: a final covers less than the interim before it, and an
    /// `UtteranceEnd` closes the final's words. The interim's later words stay unresolved.
    @Test func aFinalShorterThanItsInterimLeavesTheInterimsLaterWordsUnresolved() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(.results(.init(
            transcript: "Explain your architecture. Also include", isFinal: false, speechFinal: false,
            start: 0, end: 6.2, lastWordEnd: 6.2)))
        _ = assembler.receive(final("Explain your architecture.", start: 0, end: 4.7, lastWordEnd: 3.4))
        #expect(assembler.receive(.utteranceEnd(lastWordEnd: 3.4)) == ["Explain your architecture."])
        assembler.finishPublishing()
        #expect(assembler.hasUnresolvedSpeech, "\"Also include\" is heard but not finalized")

        #expect(assembler.receive(final("Also include your tests.", start: 4.7, end: 7, speechFinal: true))
            == ["Also include your tests."])
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    /// Word timing marks heard speech, so an interim window's trailing silence is not speech.
    @Test func trailingSilenceInAnInterimWindowIsNotSpeech() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(.results(.init(
            transcript: "Explain your architecture.", isFinal: false, speechFinal: false,
            start: 0, end: 6.2, lastWordEnd: 3.4)))
        _ = assembler.receive(final("Explain your architecture.", start: 0, end: 4.7, lastWordEnd: 3.4))
        _ = assembler.receive(.utteranceEnd(lastWordEnd: 3.4))
        assembler.finishPublishing()
        #expect(!assembler.hasUnresolvedSpeech)
    }

    /// The second review's second sequence: a retired socket's late final must not advance the
    /// replacement's clock and settle its speech.
    @Test func aRetiredSocketsLateEventCannotSettleTheReplacementsSpeech() {
        var assembler = Self.liveAssembler()
        assembler.reset(socket: 2)
        _ = assembler.receive(interim("New words", start: 0, end: 1), socket: 2)
        #expect(assembler.hasUnresolvedSpeech)

        #expect(assembler.receive(final("Old words.", start: 50, end: 51, speechFinal: true), socket: 1).isEmpty)
        #expect(assembler.hasUnresolvedSpeech)
        _ = assembler.receive(interim("New words again", start: 0, end: 1.5), socket: 2)
        #expect(assembler.hasUnresolvedSpeech)
    }
}

private extension DeepgramUtteranceAssembler {
    /// Most cases run on the one socket `liveAssembler()` opened.
    mutating func receive(_ event: DeepgramLiveSession.Event) -> [String] {
        receive(event, socket: 1)
    }
}


extension DeepgramUtteranceAssemblerTests {
    @Test func finalizedRangeUsesWordsRatherThanTheRecognitionWindow() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(.results(.init(transcript: "first", isFinal: true, speechFinal: false,
            start: 0, end: 4, lastWordEnd: 2, firstWordStart: 1)))
        _ = assembler.receive(.results(.init(transcript: "second", isFinal: true, speechFinal: true,
            start: 4, end: 8, lastWordEnd: 6, firstWordStart: 5)))
        #expect(assembler.publishedSpeechInterval == SpeechInterval(startedAt: 1, endedAt: 6))
        assembler.finishPublishing()
        assembler.reset(socket: 2)
        #expect(assembler.publishedSpeechInterval == nil)
    }

    @Test func missingWordTimingCannotBecomeAMeasuredSpeechRange() {
        var assembler = Self.liveAssembler()
        _ = assembler.receive(final("untimed", start: 0, end: 4, speechFinal: true))
        #expect(assembler.publishedSpeechInterval == nil)
    }

    @Test func captureRestartPreservesMeasuredSpeechOnBothSidesOfTheBreak() {
        var sequence = AudioCaptureSequence()
        var clock = DeepgramLiveSession.AudioClock()
        clock.recordSentAudio(sequenceNumber: sequence.next(), capturedAt: 10, duration: 1)
        sequence.markDiscontinuity()
        clock.recordSentAudio(sequenceNumber: sequence.next(), capturedAt: 20, duration: 1)

        #expect(clock.sessionInterval(SpeechInterval(startedAt: 0.25, endedAt: 0.75))
            == SpeechInterval(startedAt: 10.25, endedAt: 10.75))
        #expect(clock.sessionInterval(SpeechInterval(startedAt: 1.25, endedAt: 1.75))
            == SpeechInterval(startedAt: 20.25, endedAt: 20.75))
        #expect(clock.sessionInterval(SpeechInterval(startedAt: 0.75, endedAt: 1.25)) == nil)
    }

    @Test func finalCrossingCaptureRestartRetainsTextWithEstimatedTiming() throws {
        var sequence = AudioCaptureSequence()
        var clock = DeepgramLiveSession.AudioClock()
        clock.recordSentAudio(sequenceNumber: sequence.next(), capturedAt: 10, duration: 1)
        sequence.markDiscontinuity()
        clock.recordSentAudio(sequenceNumber: sequence.next(), capturedAt: 20, duration: 1)
        var assembler = Self.liveAssembler()
        let segments = assembler.receive(.results(.init(
            transcript: "Keep these words", isFinal: true, speechFinal: true,
            start: 0.75, end: 1.25, lastWordEnd: 1.25, firstWordStart: 0.75)), socket: 1)
        let interval = clock.sessionInterval(assembler.publishedSpeechInterval)
        #expect(interval == nil)
        let text = try #require(DeepgramLiveSession.joinedTranscript(segments, speaker: .me))
        let transcript = RollingTranscript()
        let coordinator = TranscriptionCoachingCoordinator(
            speaker: .me, transcript: transcript, clock: ManualClock(now: 30), sessionStart: 0,
            transcriptBatchingWindow: 0, silenceTimeout: 60, silenceMaxInterval: 60,
            silenceEnabled: false, onTurnEnd: { _ in }, onSilence: { _ in },
            onTranscriptionWorkChanged: { _ in })
        coordinator.start()
        #expect(coordinator.recordFinalizedTranscript(
            text, spokenAt: interval?.startedAt, spokenEndAt: interval?.endedAt, source: "deepgram-live"))
        coordinator.stop()
        #expect(transcript.count == 1)
        #expect(transcript.renderFrom(index: 0).text.contains("Keep these words"))
        #expect(transcript.renderFrom(index: 0).text.contains("estimated from transcript receipt"))
        #expect(transcript.renderFrom(index: 0).lines.first?.timingIsEstimated == true)
    }

    @Test func sentAudioGapRejectsCrossingFinalsButLaterMeasuredSpeechRecovers() {
        var clock = DeepgramLiveSession.AudioClock()
        let words = SpeechInterval(startedAt: 0.1, endedAt: 0.2)
        clock.recordSentAudio(sequenceNumber: 10, capturedAt: 10, duration: 0.1)
        clock.recordSentAudio(sequenceNumber: 11, capturedAt: 10.15, duration: 0.1)
        #expect(clock.sessionInterval(words) == SpeechInterval(startedAt: 10.1, endedAt: 10.2))
        clock.recordSentAudio(sequenceNumber: 13, capturedAt: 11, duration: 0.1)
        #expect(clock.sessionInterval(words) == SpeechInterval(startedAt: 10.1, endedAt: 10.2))
        clock.recordSentAudio(sequenceNumber: 14, capturedAt: 11.1, duration: 0.1)
        #expect(clock.sessionInterval(words) == SpeechInterval(startedAt: 10.1, endedAt: 10.2))
        #expect(clock.sessionInterval(SpeechInterval(startedAt: 0.1, endedAt: 0.3)) == nil)
        let recovered = clock.sessionInterval(SpeechInterval(startedAt: 0.25, endedAt: 0.35))
        #expect(abs((recovered?.startedAt ?? 0) - 11.05) < 0.000_001)
        #expect(abs((recovered?.endedAt ?? 0) - 11.15) < 0.000_001)
        #expect(clock.sessionInterval(SpeechInterval(startedAt: 0.3, endedAt: 0.5)) == nil)
        clock = .init()
        clock.recordSentAudio(sequenceNumber: 15, capturedAt: 12, duration: 0.2)
        #expect(clock.sessionInterval(words) == SpeechInterval(startedAt: 12.1, endedAt: 12.2))
    }
}
