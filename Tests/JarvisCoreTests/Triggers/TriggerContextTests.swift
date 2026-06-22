import Testing
@testable import JarvisCore

@Suite struct TriggerContextTests {
    @Test func turnEndPromptLineIsSpeakerNeutralAndDescribesSessionElapsed() {
        let ctx = TriggerContext(reason: .turnEnd, secondsSinceLastSpeech: 0, sessionElapsedSeconds: 95)
        #expect(ctx.promptLine == "Trigger: a turn just ended. The session has been running for 95s.")
    }

    @Test func silencePromptLineDescribesQuietDurationAndSessionElapsed() {
        let ctx = TriggerContext(reason: .silence(secondsQuiet: 120), secondsSinceLastSpeech: 120, sessionElapsedSeconds: 600)
        #expect(ctx.promptLine == "Trigger: the user has been silent for 120s. The session has been running for 600s.")
    }
}
