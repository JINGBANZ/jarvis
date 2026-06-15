import Testing
@testable import JarvisCore

@Suite struct TranscriptTests {
    @Test func windowFiltersByAgeAndFormatsTimestamps() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "let me read the problem", at: 0))
        t.append(.init(speaker: .me, text: "maybe a hash map", at: 102))   // 01:42
        let rendered = t.renderWindow(seconds: 90, now: 120)
        #expect(!rendered.contains("read the problem"))
        #expect(rendered.contains("[01:42] me: maybe a hash map"))
    }

    @Test func silenceDurationFromLastLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "hmm", at: 50))
        #expect(abs(t.silenceDuration(now: 70) - 20) < 0.001)
    }

    @Test func silenceDurationWhenEmptyIsZero() {
        let t = RollingTranscript()
        #expect(abs(t.silenceDuration(now: 70) - 0) < 0.001)
    }

    /// For server-side conversation state we send only NEW lines each turn (the rest is already in
    /// the conversation), tracked by line INDEX — no clock-domain confusion possible.
    @Test func renderFromReturnsOnlyLinesAtOrAfterIndex() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "first", at: 10))
        t.append(.init(speaker: .me, text: "second", at: 30))
        #expect(t.count == 2)
        let rendered = t.renderFrom(index: 1)
        #expect(!rendered.contains("first"))
        #expect(rendered.contains("[00:30] me: second"))
    }

    @Test func renderFromEmptyWhenCaughtUp() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10))
        #expect(t.renderFrom(index: t.count).isEmpty)
    }

    /// Out-of-range indices are clamped, not a crash (defensive against a stale sentCount).
    @Test func renderFromClampsOutOfRange() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10))
        #expect(t.renderFrom(index: 99).isEmpty)
        #expect(t.renderFrom(index: -5).contains("only"))
    }
}
