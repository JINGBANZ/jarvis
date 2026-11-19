import Foundation
import Testing
@testable import JarvisCore

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
            automaticAttemptDelay: { _ in },
            activity: nil
        )
        return (driver, transcript)
    }

    private func lastUserMessage(_ brain: ScriptedBrain) -> String? {
        brain.calls.last?.first { $0.role == .user }?.text
    }

    @Test func turnEndSendsTheDeltaBlockAlone() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "brute force two-sum", at: 0, endedAt: 0))

        await driver.handleTrigger(.turnEnd)

        #expect(lastUserMessage(brain) == "[00:00-00:00] me: brute force two-sum")
    }

    @Test func emptySpeechSendsOnlyTheTriggerNote() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: ManualClock(now: 0))

        await driver.handleTrigger(.silence(secondsQuiet: 30))

        let msg = lastUserMessage(brain)
        #expect(msg == "[00:00] (no speech for 30s)")
        #expect(msg?.contains("New since last turn") == false)
        #expect(msg?.contains("nothing new") == false)
    }

    @Test func silenceWithNewSpeechCarriesBlockThenNote() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "hmm let me think", at: 0, endedAt: 0))

        await driver.handleTrigger(.silence(secondsQuiet: 45))

        #expect(lastUserMessage(brain) ==
                "[00:00-00:00] me: hmm let me think\n\n[00:00] (no speech for 45s)")
    }

    @Test func silenceAfterFragmentCarriesNoFreshSpeechBlock() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet1")]),
            .init(toolCalls: [.staySilent(callId: "quiet2")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "one pass", at: 0, endedAt: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 30)) == .silentByModel)

        let userMessages = brain.calls[1].filter { $0.role == .user }.compactMap(\.text)
        #expect(userMessages == [
            "[00:00-00:00] me: one pass",
            "[00:00] (no speech for 30s)",
        ])
    }
}


extension CoachDriverContextMessageTests {
    @Test func twoQuietDecisionsRemainNativeLinkedHistoryWithoutFreshSpeech() async throws {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet1")]),
            .init(toolCalls: [.staySilent(callId: "quiet2")]),
            .init(toolCalls: [.staySilent(callId: "quiet3")]),
        ])
        let clock = ManualClock(now: 100)
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 5)) == .silentByModel)
        clock.advance(by: 3)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 8)) == .silentByModel)
        clock.advance(by: 3)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 11)) == .silentByModel)
        let history = brain.calls[2]
        for (id, time) in [("quiet1", "00:00"), ("quiet2", "00:03")] {
            let call = try #require(history.flatMap { $0.toolCalls ?? [] }.first { $0.id == id })
            #expect(call.name == "stay_silent")
            #expect(call.argumentsJSON == "{}")
            #expect(history.contains { $0.role == .tool && $0.toolCallId == id && $0.text == "Silent at \(time)." })
        }
    }
}
