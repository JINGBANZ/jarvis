import Foundation
import Testing
@testable import JarvisCore

/// How the per-turn user message is assembled (CoachDriver.runTurn): new speech is wrapped in a
/// "New since last turn:" block ONLY when there is any, followed by the trigger note ONLY when the
/// trigger has one — a turn-end has none (the stamped delta already says the user just spoke), so
/// its message is the bare block; a silence wake-up with nothing said is the bare note.
@Suite struct CoachDriverContextMessageTests {
    private func makeDriver(brain: BrainClient, clock: Clock) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI,
            modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: target, brain: brain),
            ]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock,
            automaticAttemptDelay: { _ in }
        )
        return (driver, transcript)
    }

    /// The first user-role message the brain saw on the latest call.
    private func lastUserMessage(_ brain: ScriptedBrain) -> String? {
        brain.calls.last?.first { $0.role == .user }?.text
    }

    /// A turn-end sends the delta block and nothing else: no boilerplate trigger sentence to be
    /// committed and re-billed every turn — the [mm:ss] stamps already carry the timing.
    @Test func turnEndSendsTheDeltaBlockAlone() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "brute force two-sum", at: 0))

        await driver.handleTrigger(.turnEnd)

        #expect(lastUserMessage(brain) == "New since last turn:\n[00:00] me: brute force two-sum")
    }

    /// No new speech (a silence wake-up with nothing said): the message is the bare trigger note —
    /// no "New since last turn" wrapper and no "(nothing new)" filler burying the real signal.
    @Test func emptySpeechSendsOnlyTheTriggerNote() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: ManualClock(now: 0))   // empty transcript

        await driver.handleTrigger(.silence(secondsQuiet: 30))

        let msg = lastUserMessage(brain)
        #expect(msg == "[00:00] (no speech for 30s)")
        #expect(msg?.contains("New since last turn") == false)
        #expect(msg?.contains("nothing new") == false)
    }

    /// A silence wake-up WITH unsent speech carries both: the delta block first, then the note.
    @Test func silenceWithNewSpeechCarriesBlockThenNote() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "hmm let me think", at: 0))

        await driver.handleTrigger(.silence(secondsQuiet: 45))

        #expect(lastUserMessage(brain) ==
                "New since last turn:\n[00:00] me: hmm let me think\n\n[00:00] (no speech for 45s)")
    }

    /// A fragment committed after `stay_silent` remains useful history, but it must not masquerade as
    /// fresh speech on a later proactive silence check. The current turn is the final bare note.
    @Test func silenceAfterFragmentCarriesNoFreshSpeechBlock() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet1")]),
            .init(toolCalls: [.staySilent(callId: "quiet2")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "one pass", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 30)) == .silentByModel)

        let userMessages = brain.calls[1].filter { $0.role == .user }.compactMap(\.text)
        #expect(userMessages == [
            "New since last turn:\n[00:00] me: one pass",
            "[00:00] (no speech for 30s)",
        ])
    }
}
