import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachDriverInterviewFormatTests {
    private func makeDriver(
        brain: BrainClient,
        interviewFormat: InterviewFormat?,
        clock: Clock = ManualClock(now: 100)
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let route = ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: brain)])
        let driver = CoachDriver(
            config: .default, transcript: transcript, route: route,
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock,
            automaticAttemptDelay: { _ in },
            interviewFormatAddendum: interviewFormat?.promptAddendum ?? "")
        return (driver, transcript)
    }

    private func staySilentScript() -> [BrainResponse] {
        [.init(toolCalls: [.staySilent(callId: "s1")],
               rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")])]
    }

    @Test func systemPromptIncludesSystemDesignGuidanceWhenExplicitlySelected() async {
        let brain = ScriptedBrain(script: staySilentScript())
        let (driver, transcript) = makeDriver(brain: brain, interviewFormat: .systemDesign)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("functional requirements")
        })
    }

    @Test func systemPromptIncludesCodingGuidanceWhenExplicitlySelected() async {
        let brain = ScriptedBrain(script: staySilentScript())
        let (driver, transcript) = makeDriver(brain: brain, interviewFormat: .coding)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls[0].contains {
            $0.role == .system
                && ($0.text ?? "").hasPrefix(JarvisPrompts.Coach.system)
                && $0.text != JarvisPrompts.Coach.system
        })
    }

    @Test func systemPromptOmitsFormatGuidanceForBehavioral() async {
        let brain = ScriptedBrain(script: staySilentScript())
        let (driver, transcript) = makeDriver(brain: brain, interviewFormat: .behavioral)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(!brain.calls[0].contains {
            $0.role == .system && ($0.text ?? "").contains("Interview format")
        })
    }

    /// No selection means no behavior change at all for a user who never opens this setting — the
    /// system prompt sent is byte-for-byte the same as if the feature didn't exist. Guard against a
    /// regression back to "no selection guesses from whatever formats have content," which silently
    /// asserted a false "this is a system-design interview" claim into every session by default.
    @Test func systemPromptEqualsBaseCoachPromptWhenNoneSelected() async {
        let brain = ScriptedBrain(script: staySilentScript())
        let (driver, transcript) = makeDriver(brain: brain, interviewFormat: nil)
        transcript.append(.init(speaker: .me, text: "let me think out loud", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.calls[0].contains {
            $0.role == .system && $0.text == JarvisPrompts.Coach.system
        })
    }
}
