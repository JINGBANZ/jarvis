import Testing
@testable import JarvisCore

@Suite struct TranscriptTests {
    /// Appended out of spoken order, as when the two sockets finish at different speeds.
    @Test func rendersBothSpeakersStampedInSpokenOrder() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "I'd use two pointers", at: 8, endedAt: 8))
        t.append(.init(speaker: .them, text: "how would you reverse a list?", at: 5, endedAt: 5))
        let rendered = t.renderFrom(index: 0).text
        #expect(rendered.contains("[00:05-00:05] them: how would you reverse a list?"))
        #expect(rendered.contains("[00:08-00:08] me: I'd use two pointers"))
        #expect(rendered.range(of: "them:")!.lowerBound < rendered.range(of: "me:")!.lowerBound)
    }

    @Test func silenceDurationFromLastLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "hmm", at: 50, endedAt: 50))
        #expect(abs(t.silenceDuration(now: 70) - 20) < 0.001)
    }

    @Test func silenceDurationWhenEmptyIsWholeSession() {
        let t = RollingTranscript()
        #expect(abs(t.silenceDuration(now: 70) - 70) < 0.001)
    }

    @Test func silenceDurationUsesLatestSpokenNotLastAppended() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "later", at: 100, endedAt: 100))
        t.append(.init(speaker: .them, text: "earlier", at: 95, endedAt: 95))
        #expect(abs(t.silenceDuration(now: 120) - 20) < 0.001)    // 120 - 100, not 120 - 95
    }

    @Test func renderFromReturnsOnlyLinesAtOrAfterIndex() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "first", at: 10, endedAt: 10))
        t.append(.init(speaker: .me, text: "second", at: 30, endedAt: 30))
        #expect(t.count == 2)
        let rendered = t.renderFrom(index: 1)
        #expect(!rendered.text.contains("first"))
        #expect(rendered.text.contains("[00:30-00:30] me: second"))
        #expect(rendered.upTo == 2)
    }

    @Test func renderFromOrdersBySpokenTime() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "two pointers", at: 8, endedAt: 8))
        t.append(.init(speaker: .them, text: "reverse a list?", at: 5, endedAt: 5))
        let text = t.renderFrom(index: 0).text
        #expect(text.range(of: "them:")!.lowerBound < text.range(of: "me:")!.lowerBound)
    }

    @Test func renderFromExposesTheDeltaLines() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "my idea", at: 1, endedAt: 1))
        t.append(.init(speaker: .them, text: "hmm", at: 5, endedAt: 5))
        #expect(t.renderFrom(index: 0).lines.map(\.text) == ["my idea", "hmm"])
        #expect(t.renderFrom(index: 1).lines.map(\.speaker) == [.them])
        #expect(t.renderFrom(index: t.count).lines.isEmpty)
    }

    @Test func renderFromEmptyWhenCaughtUp() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10, endedAt: 10))
        #expect(t.renderFrom(index: t.count).text.isEmpty)
    }

    @Test func renderFromClampsOutOfRange() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10, endedAt: 10))
        #expect(t.renderFrom(index: 99).text.isEmpty)
        #expect(t.renderFrom(index: -5).text.contains("only"))
    }
}

extension TranscriptTests {
    @Test func rendersMeasuredEndsAndUsesTheLatestEndForSilence() {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "a long explanation", at: 3, endedAt: 12))
        transcript.append(.init(speaker: .them, text: "an overlapping question", at: 8, endedAt: 10))
        #expect(transcript.renderFrom(index: 0).text == "[00:03-00:12] me: a long explanation\n[00:08-00:10] them: an overlapping question")
        #expect(transcript.silenceDuration(now: 14) == 2)
    }

    @Test func rejectsUnmeasuredOrInvalidSpeechIntervals() {
        #expect(SpeechInterval(startedAt: 3, endedAt: 2) == nil)
        #expect(SpeechInterval(startedAt: .nan, endedAt: 4) == nil)
        #expect(SpeechInterval(startedAt: 3, endedAt: .infinity) == nil)
        #expect(SpeechInterval(startedAt: -1, endedAt: 4) == nil)
    }
}


extension TranscriptTests {
    @Test func receiptChronologyDoesNotMasqueradeAsMeasuredSpeech() {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "retained words", observedAt: 42, speechInterval: nil))
        let snapshot = transcript.renderFrom(index: 0)
        #expect(snapshot.text == "[speech time unknown] me: retained words")
        #expect(snapshot.lines.first?.at == 42)
        #expect(snapshot.lines.first?.speechInterval == nil)
        #expect(!snapshot.text.contains("00:42"))
    }
}
