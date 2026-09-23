import Foundation
import Testing
@testable import JarvisCore

/// @unchecked: all mutable state is guarded by `lock`.
final class RecordingActivity: ActivityEventRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ActivityEvent] = []
    var events: [ActivityEvent] { lock.withLock { _events } }
    var kinds: [ActivityEvent.Kind] { events.map(\.rendered.kind) }
    var loadedSkillNames: [String] {
        events.compactMap {
            guard case .capabilityLoaded(let kind, let name) = $0, kind == .skill else { return nil }
            return name
        }
    }
    func record(_ event: ActivityEvent, at date: Date) {
        lock.withLock { _events.append(event) }
    }
}

@Suite(.serialized) struct CoachToolLoadingTests {
    private let prepConfigured = CoachCapabilities.compose(
        disabledTools: [], prepSourcesConfigured: true)
    private let beforeLoad = ["capture_screen", "speak", "stay_silent", "load_tool"]
    private let afterLoad = ["capture_screen", "speak", "stay_silent", "call_tool"]

    private func loadCall(_ name: String, id: String = "l1") -> BrainResponse {
        .init(toolCalls: [.loadTool(callId: id, name: name)],
              rawToolCalls: [RawToolCall(id: id, name: "load_tool",
                                         argumentsJSON: #"{"name":"\#(name)"}"#)])
    }

    private var speak: BrainResponse {
        .init(toolCalls: [.speak(callId: "s1", lines: ["Name the constraint first."])],
              rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                         argumentsJSON: #"{"lines":["Name the constraint first."]}"#)])
    }

    private func callViaDispatcher(_ name: String, _ argumentsJSON: String, id: String = "c1",
                                   parsed: ToolInvocation?) -> BrainResponse {
        let escaped = argumentsJSON.replacingOccurrences(of: "\"", with: "\\\"")
        return .init(toolCalls: parsed.map { [$0] } ?? [],
                     rawToolCalls: [RawToolCall(
                        id: id, name: "call_tool",
                        argumentsJSON: #"{"name":"\#(name)","arguments":"\#(escaped)"}"#)])
    }

    private func makeDriver(
        brain: BrainClient,
        capabilities: CoachCapabilities,
        prepMaterial: (any PrepMaterialSearching)? = nil,
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
            capabilities: capabilities,
            prepMaterial: prepMaterial)
        return (driver, transcript)
    }

    private func makeRunner(
        capabilities: CoachCapabilities,
        activity: (any ActivityEventRecording)? = nil
    ) -> CoachAttemptRunner {
        CoachAttemptRunner(
            config: .default, transcript: RollingTranscript(), screen: FakeScreen(),
            overlay: FakeOverlay(), clock: ManualClock(now: 100), sessionStart: 0,
            coachingAttempts: nil, activity: activity, ledger: CoachTranscriptLedger(),
            capabilities: capabilities)
    }

    private func run(
        _ runner: CoachAttemptRunner, brain: BrainClient,
        prepMaterial: (any PrepMaterialSearching)? = nil
    ) async -> CoachAttemptRunner.AttemptResult {
        var work = CoachAttemptRunner.PendingCoachingWork(reason: .turnEnd)
        work.prepNotesObservation = .user("a question is pending")
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return await runner.runAttempt(work, using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: nil, onSelected: nil,
            prepMaterial: prepMaterial)).result
    }

    @Test func aLoadedToolIsCalledThroughCallToolWithoutChangingTheHotList() async throws {
        let search = FakePrepMaterialSearch(results: [PrepMaterialSearchResult(
            sourceDisplayName: "system-design.md", text: "token bucket notes")])
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            callViaDispatcher("search_prep_notes", #"{"query":"rate limiter"}"#,
                              parsed: .searchPrepNotes(callId: "c1", query: "rate limiter")),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, prepMaterial: search, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "l1" })
        #expect(result.text?.contains(searchPrepNotesTool.parametersJSON) == true)
        #expect(result.text?.contains("call_tool") == true)
        #expect(result.text?.contains("# Prep material") == true)
        let offered = brain.offeredTools.map { $0.map(\.name) }
        #expect(offered.count == 3)
        #expect(offered.allSatisfy { $0 == prepConfigured.tools.map(\.name) })
        #expect(search.queries == ["rate limiter"])
        #expect(activity.kinds == [.capabilityLoaded, .prepNotesSearched, .tip])
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase)
            == [.initial, .loadToolContinuation, .searchPrepNotesContinuation])
    }

    @Test func aSpentLoaderLeavesTheChoiceAndACallToItIsRefused() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"), loadCall("search_prep_notes", id: "l2"), speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured,
            prepMaterial: FakePrepMaterialSearch(), activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(brain.toolChoices == [.allowed(beforeLoad), .allowed(afterLoad), .allowed(afterLoad)])
        let second = try #require(brain.calls[2].first { $0.toolCallId == "l2" })
        #expect(second.text == JarvisPrompts.Coach.notPermitted("load_tool", callable: afterLoad))
        #expect(second.text?.contains("# Prep material") == false)
        #expect(activity.kinds == [.capabilityLoaded, .tip])
    }

    @Test func anUnknownLoadNameIsAnsweredAndTheTurnContinues() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [loadCall("read_my_email"), speak])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured,
            prepMaterial: FakePrepMaterialSearch(), activity: activity)
        transcript.append(.init(speaker: .me, text: "what should I say here", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "l1" })
        #expect(result.text == JarvisPrompts.Coach.toolUnavailable("read_my_email"))
        #expect(activity.kinds == [.tip])
    }

    @Test func aLoadInAFailedAttemptIsMadeAgainByTheNext() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            .init(toolCalls: [], incompleteReason: "max_output_tokens"),
            loadCall("search_prep_notes", id: "l2"),
            speak,
        ])

        guard case .failed(let outcome, _, _) = await run(runner, brain: brain) else {
            Issue.record("expected the truncated response to fail the attempt"); return
        }
        #expect(outcome == .truncated)

        guard case .completed(let second) = await run(runner, brain: brain) else {
            Issue.record("expected the second attempt to commit a turn"); return
        }
        #expect(second == .spoke)
        let result = try #require(brain.calls[3].first { $0.toolCallId == "l2" })
        #expect(result.text?.contains(searchPrepNotesTool.parametersJSON) == true)
    }

    @Test func aCommittedLoadIsRememberedByTheNextAttempt() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"), speak, loadCall("search_prep_notes", id: "l2"), speak,
        ])

        _ = await run(runner, brain: brain)
        _ = await run(runner, brain: brain)

        #expect(brain.toolChoices[2] == .allowed(afterLoad))
        let second = try #require(brain.calls[3].first { $0.toolCallId == "l2" })
        #expect(second.text == JarvisPrompts.Coach.notPermitted("load_tool", callable: afterLoad))
        #expect(brain.offeredTools.allSatisfy { $0.map(\.name) == prepConfigured.tools.map(\.name) })
    }

    @Test func aCallToAToolTheSessionDoesNotOfferIsRefused() async throws {
        let search = FakePrepMaterialSearch()
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"rate limiter"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain,
            capabilities: .compose(disabledTools: ["search_prep_notes"],
                                   prepSourcesConfigured: true),
            prepMaterial: search, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(result.text == JarvisPrompts.Coach.toolUnavailable("search_prep_notes"))
        #expect(search.queries.isEmpty)
        #expect(activity.kinds == [.tip])
    }

    @Test func aDeferredToolCalledByNameIsPointedAtCallTool() async throws {
        let search = FakePrepMaterialSearch(results: [])
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "q")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_prep_notes",
                                             argumentsJSON: #"{"query":"q"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(brain: brain, capabilities: prepConfigured, prepMaterial: search)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let answer = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(answer.text == JarvisPrompts.Coach.rejected(.notCallableByName("search_prep_notes")))
        #expect(search.queries.isEmpty)
    }

    @Test func anAutomaticTurnRefusesCallToolBeforeALoad() async throws {
        let search = FakePrepMaterialSearch()
        let brain = ScriptedBrain(script: [
            callViaDispatcher("search_prep_notes", #"{"query":"rate limiter"}"#,
                              parsed: .searchPrepNotes(callId: "c1", query: "rate limiter")),
            speak,
        ])
        let (driver, transcript) = makeDriver(brain: brain, capabilities: prepConfigured, prepMaterial: search)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(brain.toolChoices == [.allowed(beforeLoad), .allowed(beforeLoad)])
        let answer = try #require(brain.calls[1].first { $0.toolCallId == "c1" })
        #expect(answer.text == JarvisPrompts.Coach.notPermitted("call_tool", callable: beforeLoad))
        #expect(search.queries.isEmpty)
    }

    @Test func aPressPermitsCallToolOnlyOnceSomethingIsLoaded() async throws {
        let search = FakePrepMaterialSearch(results: [PrepMaterialSearchResult(
            sourceDisplayName: "behavioral.md", text: "the migration I led")])
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            callViaDispatcher("search_prep_notes", #"{"query":"disagreement"}"#,
                              parsed: .searchPrepNotes(callId: "c1", query: "disagreement")),
            speak,
        ])
        let (driver, _) = makeDriver(brain: brain, capabilities: prepConfigured, prepMaterial: search)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == [
            .allowed(["speak", "load_tool"]),
            .allowed(["speak", "call_tool"]),
            .allowed(["speak", "call_tool"]),
        ])
        #expect(search.queries == ["disagreement"])
    }

    @Test func aCallToolThatRoutesToAFixedToolIsAnsweredWithCallToolsSchema() async throws {
        let brain = ScriptedBrain(script: [
            callViaDispatcher("capture_screen", "{}", parsed: nil),
            speak,
        ])
        let (driver, transcript) = makeDriver(brain: brain, capabilities: prepConfigured)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let answer = try #require(brain.calls[1].first { $0.toolCallId == "c1" })
        let callTool = try #require(prepConfigured.tool(named: "call_tool"))
        #expect(answer.text == JarvisPrompts.Coach.argumentsRejected(callTool))
    }

    @Test func aMalformedRoutedCallIsAnsweredWithTheRoutedToolsSchema() async throws {
        let brain = ScriptedBrain(script: [
            callViaDispatcher("search_prep_notes", "{}", parsed: nil),
            callViaDispatcher("nope", "{}", id: "c2", parsed: nil),
            speak,
        ])
        let (driver, transcript) = makeDriver(brain: brain, capabilities: prepConfigured)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let malformed = try #require(brain.calls[1].first { $0.toolCallId == "c1" })
        #expect(malformed.text == JarvisPrompts.Coach.argumentsRejected(searchPrepNotesTool))
        let unknown = try #require(brain.calls[2].first { $0.toolCallId == "c2" })
        #expect(unknown.text == JarvisPrompts.Coach.toolUnavailable("nope"))
    }

    @Test func searchingWithNoIndexAnswersAndKeepsCoaching() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_prep_notes"),
            .init(toolCalls: [.searchPrepNotes(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "call_tool",
                                             argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"rate limiter\"}"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, prepMaterial: nil, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[2].first { $0.toolCallId == "p1" })
        #expect(result.text == JarvisPrompts.Coach.prepNotesUnavailable)
        #expect(activity.kinds == [.capabilityLoaded, .prepNotesUnavailable, .tip])
    }

    @Test(arguments: [(6, true), (7, false)])
    func theToolLoopAllowsSevenResponses(captures: Int, commits: Bool) async {
        let capture = BrainResponse(
            toolCalls: [.captureScreen(callId: "c1")],
            rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
        let runner = makeRunner(capabilities: .default)
        let brain = ScriptedBrain(script: Array(repeating: capture, count: captures) + [speak])

        let result = await run(runner, brain: brain)

        if commits {
            guard case .completed(let outcome) = result else {
                Issue.record("expected the seventh response to be allowed"); return
            }
            #expect(outcome == .spoke)
        } else {
            guard case .failed(let outcome, _, _) = result else {
                Issue.record("expected an eighth response to exhaust the loop"); return
            }
            #expect(outcome == .exhausted)
        }
        #expect(brain.calls.count == min(captures + 1, 7))
    }
}
