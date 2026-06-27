import Foundation
import Testing
@testable import JarvisCore

/// How the per-turn user message is assembled (CoachDriver.runTurn): new speech is wrapped in a
/// "New since last turn:" block ONLY when there is any, and the turn always ends with the trigger
/// line. A turn with no new speech (a silence wake-up, or a manual hint with nothing said since)
/// must lead with the trigger line alone — no empty wrapper, no "(nothing new)" filler.
@Suite struct CoachDriverContextMessageTests {
    private func makeDriver(brain: BrainClient, clock: Clock) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock
        )
        return (driver, transcript)
    }

    /// The first user-role message the brain saw on the latest call.
    private func lastUserMessage(_ brain: ScriptedBrain) -> String? {
        brain.calls.last?.first { $0.role == .user }?.text
    }

    /// New speech is wrapped in the "New since last turn:" block, the trigger line follows it, and the
    /// stale "(timestamped)" header is gone (lines already carry their own [mm:ss] stamps).
    @Test func newSpeechIsWrappedAndFollowedByTheTriggerLine() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])   // stay silent → one call
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "brute force two-sum", at: 0))

        await driver.handleTrigger(.turnEnd)

        let msg = lastUserMessage(brain)
        #expect(msg?.hasPrefix("New since last turn:\n") == true)
        #expect(msg?.contains("brute force two-sum") == true)
        #expect(msg?.contains("a turn just ended") == true)   // trigger line rides along
        #expect(msg?.contains("(timestamped)") == false)      // dropped header
    }

    /// No new speech (a silence wake-up with nothing said): the message is the bare trigger line —
    /// no "New since last turn" wrapper and no "(nothing new)" filler burying the real signal.
    @Test func emptySpeechSendsOnlyTheTriggerLine() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, _) = makeDriver(brain: brain, clock: ManualClock(now: 0))   // empty transcript

        await driver.handleTrigger(.silence(secondsQuiet: 30))

        let expected = TriggerContext(reason: .silence(secondsQuiet: 30), sessionElapsedSeconds: 0).promptLine
        let msg = lastUserMessage(brain)
        #expect(msg == expected)
        #expect(msg?.contains("New since last turn") == false)
        #expect(msg?.contains("nothing new") == false)
    }
}
