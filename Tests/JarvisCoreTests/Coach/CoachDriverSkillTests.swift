import Foundation
import Testing
@testable import JarvisCore

/// A skill reaches the model only when it asks for one, and only inside the turn that asked.
@Suite(.serialized) struct CoachDriverSkillTests {
    private let skills = [
        Skill(name: "behavioral", description: "Coaching for behavioral questions.",
              body: "# Behavioral questions\n\nOrganize the answer as STAR."),
        Skill(name: "system-design", description: "Coaching for design questions.",
              body: "# System-design questions\n\nSix stages."),
    ]
    private var offered: CoachCapabilities {
        .compose(disabledTools: [], prepSourcesConfigured: false, skills: skills)
    }

    private func loadCall(_ name: String, id: String = "k1") -> BrainResponse {
        .init(toolCalls: [.loadSkill(callId: id, name: name)],
              rawToolCalls: [RawToolCall(id: id, name: "load_skill",
                                         argumentsJSON: #"{"name":"\#(name)"}"#)])
    }

    private var speak: BrainResponse {
        .init(toolCalls: [.speak(callId: "s1", lines: ["Name the situation first."])],
              rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                         argumentsJSON: #"{"lines":["Name the situation first."]}"#)])
    }

    private func makeDriver(
        brain: BrainClient,
        capabilities: CoachCapabilities,
        activity: (any ActivityEventRecording)? = nil
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in },
            activity: activity,
            capabilities: capabilities)
        return (driver, transcript)
    }

    private func makeRunner(capabilities: CoachCapabilities) -> CoachAttemptRunner {
        CoachAttemptRunner(
            config: .default, transcript: RollingTranscript(), screen: FakeScreen(),
            overlay: FakeOverlay(), clock: ManualClock(now: 100), sessionStart: 0,
            coachingAttempts: nil, activity: nil, ledger: CoachTranscriptLedger(),
            capabilities: capabilities)
    }

    private func run(_ runner: CoachAttemptRunner, brain: BrainClient)
        async -> CoachAttemptRunner.AttemptResult {
        var work = CoachAttemptRunner.PendingCoachingWork(reason: .turnEnd)
        work.prepNotesObservation = .user("a question is pending")
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return await runner.runAttempt(work, using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: nil, onSelected: nil,
            prepMaterial: nil)).result
    }

    /// The whole point of the step: catalog, load, coach — one attempt, one turn. The framing is
    /// what makes the body read as instructions rather than as data.
    @Test func aLoadedSkillGuidesTheSameAttempt() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [loadCall("behavioral"), speak])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: offered, activity: activity)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict you had.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "k1" })
        #expect(result.text?.contains("Organize the answer as STAR.") == true)
        #expect(result.text?.hasPrefix("Loaded skill: behavioral.") == true)
        #expect(result.text?.contains("extension of your action policy") == true)
        // A skill is guidance, never a callable tool: loading one adds no tool to the array, and
        // the loader stays only because the other skill is still unloaded.
        #expect(brain.offeredTools[0].map(\.name) == brain.offeredTools[1].map(\.name))
        #expect(!brain.offeredTools[1].map(\.name).contains("behavioral"))
        #expect(brain.offeredTools[1].map(\.name).contains("load_skill"))
        #expect(activity.kinds == [.capabilityLoaded, .tip])
        #expect(activity.events.contains { event in
            if case .capabilityLoaded(let kind, let name) = event {
                return kind == .skill && name == "behavioral"
            }
            return false
        })
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase)
            == [.initial, .loadSkillContinuation])
    }

    /// Loading twice returns a pointer to the conversation, never the body again.
    @Test func aSecondLoadIsAnsweredWithoutRepeatingTheGuidance() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("behavioral"), loadCall("behavioral", id: "k2"), speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: offered, activity: activity)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict you had.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let second = try #require(brain.calls[2].first { $0.toolCallId == "k2" })
        #expect(second.text == JarvisPrompts.Coach.loadSkillAlreadyLoaded("behavioral"))
        #expect(second.text?.contains("STAR") == false)
        #expect(activity.kinds == [.capabilityLoaded, .tip])
    }

    /// An unknown name — including a switched-off skill — is a plain answer, never a failure.
    @Test func anUnknownSkillNameIsAnsweredAndTheTurnContinues() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [loadCall("system-design"), speak])
        let (driver, transcript) = makeDriver(
            brain: brain,
            capabilities: .compose(disabledTools: [], disabledSkills: ["system-design"],
                                   prepSourcesConfigured: false, skills: skills),
            activity: activity)
        transcript.append(.init(speaker: .them, text: "Design a URL shortener.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "k1" })
        #expect(result.text == JarvisPrompts.Coach.skillUnavailable("system-design"))
        #expect(activity.kinds == [.tip])
    }

    /// A load belongs to the attempt that made it, so "already loaded" always points at a
    /// conversation the model can still read.
    @Test func aLoadInAFailedAttemptIsMadeAgainByTheNext() async throws {
        let runner = makeRunner(capabilities: offered)
        let brain = ScriptedBrain(script: [
            loadCall("behavioral"),
            .init(toolCalls: [], incompleteReason: "max_output_tokens"),
            loadCall("behavioral", id: "k2"),
            speak,
        ])

        guard case .failed(let outcome, _, _) = await run(runner, brain: brain) else {
            Issue.record("expected the truncated response to fail the attempt"); return
        }
        #expect(outcome == .truncated)
        guard case .completed = await run(runner, brain: brain) else {
            Issue.record("expected the second attempt to commit a turn"); return
        }

        let again = try #require(brain.calls[3].first { $0.toolCallId == "k2" })
        #expect(again.text?.contains("Organize the answer as STAR.") == true)
    }

    /// A committed load stays loaded, and the two namespaces stay apart: a tool and a skill of the
    /// same name are two separate loads.
    @Test func skillAndToolNamesCannotCollideInTheLoadedSet() async throws {
        let sameName = [Skill(name: "search_prep_notes", description: "d", body: "skill body")]
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: sameName)
        let runner = makeRunner(capabilities: capabilities)
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            .init(toolCalls: [.loadTool(callId: "t1", name: "search_prep_notes")],
                  rawToolCalls: [RawToolCall(id: "t1", name: "load_tool",
                                             argumentsJSON: #"{"name":"search_prep_notes"}"#)]),
            speak,
            loadCall("search_prep_notes", id: "k2"),
            speak,
        ])

        guard case .completed = await run(runner, brain: brain) else {
            Issue.record("expected the first attempt to commit a turn"); return
        }
        let skillResult = try #require(brain.calls[1].first { $0.toolCallId == "k1" })
        let toolResult = try #require(brain.calls[2].first { $0.toolCallId == "t1" })
        #expect(skillResult.text?.contains("skill body") == true)
        #expect(toolResult.text?.contains(searchPrepNotesTool.parametersJSON) == true)

        guard case .completed = await run(runner, brain: brain) else {
            Issue.record("expected the second attempt to commit a turn"); return
        }
        let remembered = try #require(brain.calls[4].first { $0.toolCallId == "k2" })
        #expect(remembered.text == JarvisPrompts.Coach.loadSkillAlreadyLoaded("search_prep_notes"))
    }
}
