import Testing
@testable import JarvisCore

@Suite struct TriggerContextTests {
    @Test func turnEndHasNoPromptLine() {
        let ctx = TriggerContext(reason: .turnEnd, sessionElapsedSeconds: 95)
        #expect(ctx.promptLine == nil)
    }

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

    @Test func manualHintPromptLineCarriesInstructionAndStamp() {
        let ctx = TriggerContext(reason: .manualHint, sessionElapsedSeconds: 600)
        #expect(ctx.promptLine?.hasPrefix("[10:00]") == true)
        #expect(ctx.promptLine?.contains("hint shortcut") == true)
        #expect(ctx.promptLine?.contains("running for") == false)
    }

    @Test func durationPhraseDropsZeroComponents() {
        #expect(TriggerContext.durationPhrase(120) == "2m")
        #expect(TriggerContext.durationPhrase(7200) == "2h")
    }
}
