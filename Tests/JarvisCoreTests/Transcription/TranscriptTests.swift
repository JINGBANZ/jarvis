import Testing
@testable import JarvisCore

@Suite struct TranscriptTests {
    /// Both sides of a call render with their own speaker tag (mic → `me`, system audio → `them`)
    /// and a `[mm:ss]` stamp, ordered by SPOKEN time, not append order. Here the `me` line is
    /// appended FIRST but spoken LATER (at:8) than the `them` line (at:5) — mimicking a slow "them"
    /// transcription completing after a quicker "me" one across the two concurrent sockets — so this
    /// fails unless the delta rendering sorts by `.at`.
    @Test func rendersBothSpeakersStampedInSpokenOrder() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "I'd use two pointers", at: 8))      // appended first…
        t.append(.init(speaker: .them, text: "how would you reverse a list?", at: 5)) // …but spoken earlier
        let rendered = t.renderFrom(index: 0).text
        #expect(rendered.contains("[00:05] them: how would you reverse a list?"))
        #expect(rendered.contains("[00:08] me: I'd use two pointers"))
        // them (00:05) renders before me (00:08) despite the reversed append order.
        #expect(rendered.range(of: "them:")!.lowerBound < rendered.range(of: "me:")!.lowerBound)
    }

    @Test func silenceDurationFromLastLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "hmm", at: 50))
        #expect(abs(t.silenceDuration(now: 70) - 20) < 0.001)
    }

    /// With no speech yet, the user has been silent for the whole session, so silence is measured from
    /// session start (the passed `now`), not 0 — otherwise the "are you stuck?" check, gated on
    /// `quiet >= interval`, could never fire before the first utterance.
    @Test func silenceDurationWhenEmptyIsWholeSession() {
        let t = RollingTranscript()
        #expect(abs(t.silenceDuration(now: 70) - 70) < 0.001)
    }

    /// Silence is measured from the latest SPOKEN time, not the last appended line. The two sockets
    /// append out of time order, so a `them` line spoken earlier (at:95) can land after a `me` line
    /// spoken later (at:100); silenceDuration must use 100, else it overstates quiet and can fire a
    /// spurious "are you stuck?" nudge.
    @Test func silenceDurationUsesLatestSpokenNotLastAppended() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "later", at: 100))     // appended first, spoken later
        t.append(.init(speaker: .them, text: "earlier", at: 95))  // appended last, spoken earlier
        #expect(abs(t.silenceDuration(now: 120) - 20) < 0.001)    // 120 - 100, not 120 - 95
    }

    /// The brain sees only NEW lines each turn (the rest live in the client-managed history),
    /// tracked by line INDEX — no clock-domain confusion possible.
    @Test func renderFromReturnsOnlyLinesAtOrAfterIndex() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "first", at: 10))
        t.append(.init(speaker: .me, text: "second", at: 30))
        #expect(t.count == 2)
        let rendered = t.renderFrom(index: 1)
        #expect(!rendered.text.contains("first"))
        #expect(rendered.text.contains("[00:30] me: second"))
        #expect(rendered.upTo == 2)   // the count rendered up to, from the same snapshot
    }

    /// The conversation-mode delta (renderFrom) must use the same spoken-order rendering as the full
    /// window, so the brain never sees the two paths disagree. `them` (at:5) is appended AFTER `me`
    /// (at:8), so this fails if renderFrom rendered in append order.
    @Test func renderFromOrdersBySpokenTime() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "two pointers", at: 8))
        t.append(.init(speaker: .them, text: "reverse a list?", at: 5))
        let text = t.renderFrom(index: 0).text
        #expect(text.range(of: "them:")!.lowerBound < text.range(of: "me:")!.lowerBound)
    }

    /// `lines` exposes the DELTA's raw lines (not the whole transcript) — what the coach loop's
    /// substance gate inspects before spending a brain request.
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

    /// Out-of-range indices are clamped, not a crash (defensive against a stale sentCount).
    @Test func renderFromClampsOutOfRange() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "only", at: 10))
        #expect(t.renderFrom(index: 99).text.isEmpty)
        #expect(t.renderFrom(index: -5).text.contains("only"))
    }
}
