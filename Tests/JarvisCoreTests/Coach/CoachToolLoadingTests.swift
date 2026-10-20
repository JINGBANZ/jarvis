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
        disabledTools: [], referencesAdmitted: true)

    private func loadCall(_ name: String, id: String = "l1") -> BrainResponse {
        .init(toolCalls: [.loadTool(callId: id, name: name)],
              rawToolCalls: [RawToolCall(id: id, name: "load_tool",
                                         argumentsJSON: #"{"name":"\#(name)"}"#)])
    }

    private var speak: BrainResponse {
        .init(toolCalls: [.speak(callId: "s1", hint: "Name the constraint first.")],
              rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                         argumentsJSON: #"{"hint":"Name the constraint first."}"#)])
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
        documents: (any DocumentSession)? = nil,
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
            documents: documents)
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
        documents: (any DocumentSession)? = nil
    ) async -> CoachAttemptRunner.AttemptResult {
        var work = CoachAttemptRunner.PendingCoachingWork(reason: .turnEnd)
        work.referencesObservation = .user("a question is pending")
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return await runner.runAttempt(work, using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: nil, onSelected: nil,
            documents: documents)).result
    }

    @Test func aLoadedToolIsCalledThroughCallToolWithoutChangingTheHotList() async throws {
        let search = FakeDocumentSession(results: [referenceHit(
            name: "system-design.md", text: "token bucket notes")])
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_references"),
            callViaDispatcher("search_references", #"{"query":"rate limiter"}"#,
                              parsed: .searchReferences(callId: "c1", query: "rate limiter")),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, documents: search, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "l1" })
        #expect(result.text?.contains(searchReferencesTool.parametersJSON) == true)
        #expect(result.text?.contains("call_tool") == true)
        #expect(result.text?.contains("# References") == true)
        let offered = brain.offeredTools.map { $0.map(\.name) }
        #expect(offered.count == 3)
        #expect(offered.allSatisfy { $0 == prepConfigured.tools.map(\.name) })
        #expect(search.queries == ["rate limiter"])
        #expect(activity.kinds == [.capabilityLoaded, .referencesSearched, .tip])
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase)
            == [.initial, .loadToolContinuation, .searchReferencesContinuation])
    }

    @Test func aSecondLoadIsAnsweredWithoutRepeatingTheGuidance() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            loadCall("search_references"), loadCall("search_references", id: "l2"), speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured,
            documents: FakeDocumentSession(), activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let second = try #require(brain.calls[2].first { $0.toolCallId == "l2" })
        #expect(second.text == JarvisPrompts.Coach.loadToolAlreadyLoaded("search_references"))
        #expect(second.text?.contains("# References") == false)
        #expect(activity.kinds == [.capabilityLoaded, .tip])
    }

    @Test func anUnknownLoadNameIsAnsweredAndTheTurnContinues() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [loadCall("read_my_email"), speak])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured,
            documents: FakeDocumentSession(), activity: activity)
        transcript.append(.init(speaker: .me, text: "what should I say here", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "l1" })
        #expect(result.text == JarvisPrompts.Coach.toolUnavailable("read_my_email"))
        #expect(activity.kinds == [.tip])
    }

    @Test func aLoadInAFailedAttemptIsMadeAgainByTheNext() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            loadCall("search_references"),
            .init(toolCalls: [], incompleteReason: "max_output_tokens"),
            loadCall("search_references", id: "l2"),
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
        #expect(result.text?.contains(searchReferencesTool.parametersJSON) == true)
    }

    @Test func aCommittedLoadIsRememberedByTheNextAttempt() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            loadCall("search_references"), speak, loadCall("search_references", id: "l2"), speak,
        ])

        _ = await run(runner, brain: brain)
        _ = await run(runner, brain: brain)

        let second = try #require(brain.calls[3].first { $0.toolCallId == "l2" })
        #expect(second.text == JarvisPrompts.Coach.loadToolAlreadyLoaded("search_references"))
        #expect(brain.offeredTools.allSatisfy { $0.map(\.name) == prepConfigured.tools.map(\.name) })
    }

    @Test func laterAttemptsReuseLoadedGuidanceWithoutMovingTheirOpeningPrefix() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [loadCall("search_references"), speak, speak])

        _ = await run(runner, brain: brain)
        _ = await run(runner, brain: brain)

        #expect(brain.calls[0].last?.text == "a question is pending")
        let guidance = try #require(brain.calls[1].first { $0.toolCallId == "l1" }?.text)
        #expect(guidance.contains(searchReferencesTool.parametersJSON))
        #expect(brain.calls[2].first { $0.toolCallId == "l1" }?.text == guidance)
        #expect(brain.calls[2].prefix(brain.calls[0].count).map(\.role) == brain.calls[0].map(\.role))
        #expect(brain.calls[2].prefix(brain.calls[0].count).map(\.text) == brain.calls[0].map(\.text))
        #expect(brain.calls.allSatisfy { request in
            !request.contains { $0.role == .user && $0.text?.hasPrefix("Session state:") == true }
        })
    }

    @Test func aSilentQuietCheckLeavesNoTraceInLaterAttempts() async throws {
        let runner = makeRunner(capabilities: prepConfigured)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "q1")],
                  rawToolCalls: [RawToolCall(id: "q1", name: "stay_silent", argumentsJSON: "{}")]),
            speak,
        ])
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        _ = await runner.runAttempt(
            CoachAttemptRunner.PendingCoachingWork(reason: .silence(secondsQuiet: 30)),
            using: .init(plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
                         target: target, brain: brain, summarizer: nil, onSelected: nil,
                         documents: nil))
        _ = await run(runner, brain: brain)

        func quietProbe(_ m: ChatMessage) -> Bool {
            m.role == .user && m.text?.contains("(no speech for") == true
        }
        #expect(brain.calls[0].contains(where: quietProbe))
        #expect(!brain.calls[1].contains(where: quietProbe))
    }

    @Test func aCallToAToolTheSessionDoesNotOfferIsRefused() async throws {
        let search = FakeDocumentSession()
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchReferences(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_references",
                                             argumentsJSON: #"{"query":"rate limiter"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain,
            capabilities: .compose(disabledTools: ["search_references"],
                                   referencesAdmitted: true),
            documents: search, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(result.text == JarvisPrompts.Coach.toolUnavailable("search_references"))
        #expect(search.queries.isEmpty)
        #expect(activity.kinds == [.tip])
    }

    @Test func aDeferredToolCalledByNameIsPointedAtCallTool() async throws {
        let search = FakeDocumentSession(results: [])
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchReferences(callId: "p1", query: "q")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "search_references",
                                             argumentsJSON: #"{"query":"q"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(brain: brain, capabilities: prepConfigured, documents: search)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let answer = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(answer.text == JarvisPrompts.Coach.rejected(.notCallableByName("search_references")))
        #expect(search.queries.isEmpty)
    }

    @Test func aPressPermitsCallToolOnlyOnceSomethingIsLoaded() async throws {
        let search = FakeDocumentSession(results: [referenceHit(
            name: "behavioral.md", text: "the migration I led")])
        let brain = ScriptedBrain(script: [
            loadCall("search_references"),
            callViaDispatcher("search_references", #"{"query":"disagreement"}"#,
                              parsed: .searchReferences(callId: "c1", query: "disagreement")),
            speak,
        ])
        let (driver, _) = makeDriver(brain: brain, capabilities: prepConfigured, documents: search)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.toolChoices == [
            .allowed(["speak", "load_tool"]),
            .allowed(["speak", "load_tool", "call_tool"]),
            .allowed(["speak", "load_tool", "call_tool"]),
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
            callViaDispatcher("search_references", "{}", parsed: nil),
            callViaDispatcher("nope", "{}", id: "c2", parsed: nil),
            speak,
        ])
        let (driver, transcript) = makeDriver(brain: brain, capabilities: prepConfigured)
        transcript.append(.init(speaker: .them, text: "Tell me about a conflict.", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let malformed = try #require(brain.calls[1].first { $0.toolCallId == "c1" })
        #expect(malformed.text == JarvisPrompts.Coach.argumentsRejected(searchReferencesTool))
        let unknown = try #require(brain.calls[2].first { $0.toolCallId == "c2" })
        #expect(unknown.text == JarvisPrompts.Coach.toolUnavailable("nope"))
    }

    @Test func searchingWithNoIndexAnswersAndKeepsCoaching() async throws {
        let activity = RecordingActivity()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.searchReferences(callId: "p1", query: "rate limiter")],
                  rawToolCalls: [RawToolCall(id: "p1", name: "call_tool",
                                             argumentsJSON: #"{"name":"search_references","arguments":"{\"query\":\"rate limiter\"}"}"#)]),
            speak,
        ])
        let (driver, transcript) = makeDriver(
            brain: brain, capabilities: prepConfigured, documents: nil, activity: activity)
        transcript.append(.init(speaker: .them, text: "How would you design a rate limiter?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let result = try #require(brain.calls[1].first { $0.toolCallId == "p1" })
        #expect(result.text == ReferenceToolEvidence.failure(ReferenceAccessFailure(reason: .unavailable)))
        #expect(activity.kinds == [.referencesUnavailable, .tip])
    }

    @Test func finalAutomaticResponseCanStaySilent() async {
        let capture = BrainResponse(
            toolCalls: [.captureScreen(callId: "c")],
            rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")])
        let silent = BrainResponse(
            toolCalls: [.staySilent(callId: "s")],
            rawToolCalls: [RawToolCall(id: "s", name: "stay_silent", argumentsJSON: "{}")])
        let brain = ScriptedBrain(script: Array(repeating: capture, count: 6) + [silent])
        let result = await run(makeRunner(capabilities: .default), brain: brain)
        guard case .completed(let outcome) = result else {
            Issue.record("expected the final automatic decision to stay silent"); return
        }
        #expect(outcome == .silentByModel)
        #expect(brain.calls.count == 7)
        #expect(brain.toolChoices.last == .allowed(["speak", "stay_silent"]))
    }

    @Test(arguments: [(6, true), (7, false)])
    func finalResponseMustAnswerInsteadOfCapturingAgain(captures: Int, commits: Bool) async {
        let capture = BrainResponse(
            toolCalls: [.captureScreen(callId: "c1")],
            rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
        let activity = RecordingActivity()
        let runner = makeRunner(capabilities: .default, activity: activity)
        let brain = ScriptedBrain(script: Array(repeating: capture, count: captures) + [speak])

        let result = await run(runner, brain: brain)

        if commits {
            guard case .completed(let outcome) = result else {
                Issue.record("expected the seventh response to be allowed"); return
            }
            #expect(outcome == .spoke)
        } else {
            guard case .failed(let outcome, _, _) = result else {
                Issue.record("expected a forbidden final capture to fail the attempt"); return
            }
            #expect(outcome == .brainError)
        }
        #expect(brain.toolChoices.last == .allowed(["speak", "stay_silent"]))
        #expect(activity.kinds.filter { $0 == .screenViewed }.count == 6)
        #expect(brain.calls.count == min(captures + 1, 7))
    }
}
