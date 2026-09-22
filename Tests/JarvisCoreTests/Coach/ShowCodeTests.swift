import Foundation
import Testing
@testable import JarvisCore

@Suite struct ShowCodeTests {
    private let coding = Skill(name: "coding", description: "Use when the question is a coding problem.",
                               body: "Put one fenced block in detail.")

    @Test func aColdShowCodePressPreloadsCodingAheadOfItsUserMessages() async throws {
        let brain = ScriptedBrain(script: [speak(detail: "```python\nseen = {}\n```")])
        let activity = RecordingActivity()
        let driver = makeDriver(brain, activity: activity)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)

        #expect(brain.calls.count == 1)
        let request = try #require(brain.calls.first)
        let callIndex = try #require(request.firstIndex {
            $0.toolCalls?.first?.name == CoachCapabilities.loadSkillName
        })
        let call = try #require(request[callIndex].toolCalls?.first)
        #expect(call.id.hasPrefix("runner_"))
        #expect(call.argumentsJSON == #"{"name":"coding"}"#)
        let result = request[callIndex + 1]
        #expect(result.role == .tool)
        #expect(result.toolCallId == call.id)
        #expect(result.text?.contains(coding.body) == true)
        let firstUser = try #require(request.firstIndex { $0.role == .user })
        #expect(callIndex < firstUser)
        #expect(request.last?.role == .user || request.last?.imageBase64JPEG != nil)

        #expect(activity.loadedSkillNames == ["coding"])
    }

    @Test func asecondPressDoesNotPreloadAgain() async throws {
        let brain = ScriptedBrain(script: [speak(detail: "```python\nseen = {}\n```"),
                                           speak(detail: "```python\nleft = 0\n```")])
        let activity = RecordingActivity()
        let driver = makeDriver(brain, activity: activity)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(activity.loadedSkillNames == ["coding"])
        let second: [ChatMessage] = try #require(brain.calls.last)
        let loads: [RawToolCall] = second.flatMap { $0.toolCalls ?? [] }
            .filter { $0.name == CoachCapabilities.loadSkillName }
        #expect(loads.count == 1)
    }

    @Test(arguments: [TriggerReason.manualHint, .manualExplanation, .turnEnd])
    func noOtherTriggerPreloads(_ reason: TriggerReason) async throws {
        let brain = ScriptedBrain(script: [speak(detail: nil)])
        let activity = RecordingActivity()
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "I am stuck with the loop", at: 0))
        let driver = makeDriver(brain, transcript: transcript, activity: activity)
        #expect(await driver.handleTrigger(reason) == .spoke)
        #expect(activity.loadedSkillNames.isEmpty)
        #expect(brain.calls.first?.contains { $0.toolCalls != nil } != true)
    }

    @Test func aSwitchedOffCodingSkillIsNotPreloaded() async throws {
        let brain = ScriptedBrain(script: [speak(detail: "Approach first.")])
        let activity = RecordingActivity()
        let driver = makeDriver(brain, skills: [], activity: activity)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(activity.loadedSkillNames.isEmpty)
        #expect(brain.calls.count == 1)
    }

    @Test func aFailedAttemptDiscardsThePreloadAndTheRetryDoesItAgain() async throws {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [], incompleteReason: "max_output_tokens"),
            speak(detail: "```python\nseen = {}\n```"),
        ])
        let activity = RecordingActivity()
        let driver = makeDriver(brain, activity: activity)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(brain.calls.count == 2)
        for call in brain.calls {
            #expect(call.contains { $0.toolCalls?.first?.id.hasPrefix("runner_") == true })
        }
        #expect(activity.loadedSkillNames == ["coding", "coding"])
    }

    @Test func thePreloadCommitsToTheSession() async throws {
        let brain = ScriptedBrain(script: [
            speak(detail: "```python\nseen = {}\n```"),
            .init(toolCalls: [.loadSkill(callId: "l1", name: "coding")],
                  rawToolCalls: [.init(id: "l1", name: "load_skill", argumentsJSON: #"{"name":"coding"}"#)]),
            speak(detail: nil),
        ])
        let transcript = RollingTranscript()
        let driver = makeDriver(brain, transcript: transcript)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        transcript.append(.init(speaker: .me, text: "what next?", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        let answer = try #require(brain.calls.last?.first { $0.role == .tool && $0.toolCallId == "l1" })
        #expect(answer.text == JarvisPrompts.Coach.loadSkillAlreadyLoaded("coding"))
    }

    private func speak(detail: String?) -> BrainResponse {
        var arguments: [String: Any] = ["lines": ["Start with the window state."]]
        arguments["detail"] = detail as Any? ?? NSNull()
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return .init(toolCalls: [ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: json)!],
                     rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: json)])
    }

    private func makeDriver(_ brain: BrainClient,
                            transcript: RollingTranscript = RollingTranscript(),
                            skills: [Skill]? = nil,
                            activity: (any ActivityEventRecording)? = nil) -> CoachDriver {
        let target = BrainTarget(provider: .openAI,
                                 modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return CoachDriver(
            config: .default, transcript: transcript,
            route: .init(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            plan: SessionPlan(revision: 0, screen: SessionPlan.default.screen),
            activity: activity,
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false,
                skills: skills ?? [coding]))
    }
}

