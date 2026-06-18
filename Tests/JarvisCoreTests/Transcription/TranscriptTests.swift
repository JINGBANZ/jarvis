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

    /// Both sides of a call render with their own speaker tag (mic → `me`, system audio → `them`),
    /// and the window is ordered by SPOKEN time, not append order. Here the `me` line is appended
    /// FIRST but spoken LATER (at:8) than the `them` line (at:5) — mimicking a slow "them"
    /// transcription completing after a quicker "me" one across the two concurrent sockets — so this
    /// fails unless renderWindow sorts by `.at`.
    @Test func windowRendersBothSpeakersInSpokenOrder() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "I'd use two pointers", at: 8))      // appended first…
        t.append(.init(speaker: .them, text: "how would you reverse a list?", at: 5)) // …but spoken earlier
        let rendered = t.renderWindow(seconds: 90, now: 10)
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

    @Test func silenceDurationWhenEmptyIsZero() {
        let t = RollingTranscript()
        #expect(abs(t.silenceDuration(now: 70) - 0) < 0.001)
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

    /// For server-side conversation state we send only NEW lines each turn (the rest is already in
    /// the conversation), tracked by line INDEX — no clock-domain confusion possible.
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

    // MARK: - Speaker-bleed suppression
    //
    // On speakers (no headphones) the other side's voice plays out loud, the mic picks it up, and it
    // gets transcribed a SECOND time on the `me` socket — the same words, at nearly the same instant,
    // mis-attributed to the user. Two people never say the same full sentence within the same second
    // by chance, so a `me` line that closely matches a recent `them` line is the speaker bleed; drop
    // it from what the coach sees. This is why we don't need acoustic echo cancellation on the audio.

    /// A `me` line that's a near-verbatim copy of a `them` line at nearly the same time is the mic
    /// picking up the speakers — drop it from the rendered window (keep the `them` original).
    @Test func windowDropsSpeakerBleed() {
        let t = RollingTranscript()
        t.append(.init(speaker: .them, text: "What is the time complexity?", at: 10))
        t.append(.init(speaker: .me, text: "what is the time complexity", at: 10.3)) // mic bleed
        let rendered = t.renderWindow(seconds: 90, now: 30)
        #expect(rendered.contains("them: What is the time complexity?"))
        #expect(!rendered.contains("me:"))   // the bleed copy is gone
    }

    /// A genuinely distinct `me` line near a `them` line is the user actually talking — keep it.
    @Test func windowKeepsDistinctMeLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .them, text: "What is the time complexity?", at: 10))
        t.append(.init(speaker: .me, text: "I think it's order n", at: 11))
        let rendered = t.renderWindow(seconds: 90, now: 30)
        #expect(rendered.contains("them: What is the time complexity?"))
        #expect(rendered.contains("me: I think it's order n"))
    }

    /// The two sockets complete out of order — the `me` bleed can be appended BEFORE the `them`
    /// original. Suppression must match against all `them` lines regardless of append/spoken order.
    @Test func windowDropsBleedRegardlessOfArrivalOrder() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "reverse a linked list", at: 5.2))   // bleed arrives first
        t.append(.init(speaker: .them, text: "Reverse a linked list.", at: 5.0))
        let rendered = t.renderWindow(seconds: 90, now: 30)
        #expect(rendered.contains("them: Reverse a linked list."))
        #expect(!rendered.contains("me:"))
    }

    /// Same words but spoken much later is a real restatement by the user, NOT bleed — keep it.
    /// (Bleed is simultaneous; a restatement seconds later is the user genuinely echoing an idea.)
    @Test func windowKeepsLateRestatement() {
        let t = RollingTranscript()
        t.append(.init(speaker: .them, text: "use a hash map", at: 5))
        t.append(.init(speaker: .me, text: "use a hash map", at: 60))   // 55s later
        let rendered = t.renderWindow(seconds: 120, now: 70)
        #expect(rendered.contains("them: use a hash map"))
        #expect(rendered.contains("me: use a hash map"))
    }

    /// Short backchannels ("okay", "right", "yes") are common real user speech and low-harm as bleed,
    /// so a match on a trivially short `them` line does NOT suppress the `me` line.
    @Test func windowKeepsShortBackchannel() {
        let t = RollingTranscript()
        t.append(.init(speaker: .them, text: "Okay.", at: 5))
        t.append(.init(speaker: .me, text: "okay", at: 5.3))
        let rendered = t.renderWindow(seconds: 90, now: 30)
        #expect(rendered.contains("me: okay"))
    }

    /// The conversation-mode delta (renderFrom) drops bleed too, so the brain's own memory never
    /// records the other side's words as the user's. The line index still advances past the dropped
    /// line (upTo is the raw count) so it's never re-sent.
    @Test func deltaDropsSpeakerBleed() {
        let t = RollingTranscript()
        t.append(.init(speaker: .them, text: "What is the time complexity?", at: 10))
        t.append(.init(speaker: .me, text: "what is the time complexity", at: 10.3))
        let result = t.renderFrom(index: 0)
        #expect(result.text.contains("them:"))
        #expect(!result.text.contains("me:"))
        #expect(result.upTo == 2)   // index still advances past the dropped bleed line
    }
}
