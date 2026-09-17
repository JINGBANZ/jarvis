import Testing
@testable import JarvisCore

@Suite struct TranscriptTests {
    /// Appended out of spoken order, as when the two sockets finish at different speeds.
    @Test func rendersBothSpeakersStampedInSpokenOrder() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "I'd use two pointers", at: 8))
        t.append(.init(speaker: .them, text: "how would you reverse a list?", at: 5))
        let rendered = t.renderFrom(index: 0).text
        #expect(rendered.contains("[00:05] them: how would you reverse a list?"))
        #expect(rendered.contains("[00:08] me: I'd use two pointers"))
        #expect(rendered.range(of: "them:")!.lowerBound < rendered.range(of: "me:")!.lowerBound)
    }

    @Test func silenceDurationFromLastLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "hmm", at: 50))
        #expect(abs(t.silenceDuration(now: 70) - 20) < 0.001)
    }

    @Test func silenceDurationWhenEmptyIsWholeSession() {
        let t = RollingTranscript()
        #expect(abs(t.silenceDuration(now: 70) - 70) < 0.001)
    }

    @Test func silenceDurationUsesLatestSpokenNotLastAppended() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "later", at: 100))
        t.append(.init(speaker: .them, text: "earlier", at: 95))
        #expect(abs(t.silenceDuration(now: 120) - 20) < 0.001)    // 120 - 100, not 120 - 95
    }

    @Test func renderFromReturnsOnlyLinesAtOrAfterIndex() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "first", at: 10))
        t.append(.init(speaker: .me, text: "second", at: 30))
        #expect(t.count == 2)
        let rendered = t.renderFrom(index: 1)
        #expect(!rendered.text.contains("first"))
        #expect(rendered.text.contains("[00:30] me: second"))
        #expect(rendered.upTo == 2)
    }

    @Test func renderFromOrdersBySpokenTime() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "two pointers", at: 8))
        t.append(.init(speaker: .them, text: "reverse a list?", at: 5))
        let text = t.renderFrom(index: 0).text
        #expect(text.range(of: "them:")!.lowerBound < text.range(of: "me:")!.lowerBound)
    }

    @Test func renderFromExposesTheDeltaLines() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "my idea", at: 1))
        t.append(.init(speaker: .them, text: "hmm", at: 5))
        #expect(t.renderFrom(index: 0).lines.map(\.text) == ["my idea", "hmm"])
        #expect(t.renderFrom(index: 1).lines.map(\.speaker) == [.them])
        #expect(t.renderFrom(index: t.count).lines.isEmpty)
    }

    @Test func renderFromEmptyWhenCaughtUp() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10))
        #expect(t.renderFrom(index: t.count).text.isEmpty)
    }

    @Test func renderFromClampsOutOfRange() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10))
        #expect(t.renderFrom(index: 99).text.isEmpty)
        #expect(t.renderFrom(index: -5).text.contains("only"))
    }
}
