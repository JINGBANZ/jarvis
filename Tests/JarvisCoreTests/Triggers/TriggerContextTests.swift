import Testing
@testable import JarvisCore

@Suite struct TriggerContextTests {
    /// A turn-end adds NO trigger note: the "New since last turn" block (with its [mm:ss] stamps)
    /// already says the user just spoke and when — a boilerplate sentence on top would be committed
    /// to memory and re-billed on every later request.
    @Test func turnEndHasNoPromptLine() {
        let ctx = TriggerContext(reason: .turnEnd, sessionElapsedSeconds: 95)
        #expect(ctx.promptLine == nil)
    }

    /// A silence check reads like a transcript line: the session stamp plus how long the quiet has
    /// lasted, in human units (no raw seconds arithmetic for the model or a log reader).
    @Test func silencePromptLineIsStampedAndHumanReadable() {
        let ctx = TriggerContext(reason: .silence(secondsQuiet: 146), sessionElapsedSeconds: 1225)
        #expect(ctx.promptLine == "[20:25] (no speech for 2m 26s)")
    }

    @Test func shortSilenceStaysInSeconds() {
        let ctx = TriggerContext(reason: .silence(secondsQuiet: 45), sessionElapsedSeconds: 60)
        #expect(ctx.promptLine == "[01:00] (no speech for 45s)")
    }

    @Test func hourLongSilenceSpellsHoursAndMinutes() {
        let ctx = TriggerContext(reason: .silence(secondsQuiet: 12640), sessionElapsedSeconds: 13719)
        #expect(ctx.promptLine == "[228:39] (no speech for 3h 30m)")
    }

    /// The manual hint keeps its instruction (it's rare and carries real semantics), stamped the
    /// same way — and the old raw-seconds "running for Ns" sentence is gone.
    @Test func manualHintPromptLineCarriesInstructionAndStamp() {
        let ctx = TriggerContext(reason: .manualHint, sessionElapsedSeconds: 600)
        #expect(ctx.promptLine?.hasPrefix("[10:00]") == true)
        #expect(ctx.promptLine?.contains("hint shortcut") == true)
        #expect(ctx.promptLine?.contains("running for") == false)
    }

    /// Exact-minute and exact-hour durations drop the zero component.
    @Test func durationPhraseDropsZeroComponents() {
        #expect(TriggerContext.durationPhrase(120) == "2m")
        #expect(TriggerContext.durationPhrase(7200) == "2h")
    }
}
