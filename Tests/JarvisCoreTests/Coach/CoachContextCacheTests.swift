import Foundation
import Testing
@testable import JarvisCore
import JarvisBrainProviders

@Suite(.serialized) struct CoachContextCacheTests {
    private var codingSkill: Skill {
        Skill(name: "coding", description: "Synthetic ledger coding guidance.",
              body: "# Ledger invariants\nCommit a deduplicated effect and its checkpoint atomically. Ownership transfer increments the generation and rejects writes from a previous generation. Test duplicate events, delayed events, empty partitions, and cancellation at the commit boundary.")
    }

    private var capabilities: CoachCapabilities {
        .compose(disabledTools: [], referencesAdmitted: true, skills: [codingSkill])
    }

    @Test(arguments: [BrainProvider.openAI, .claudeSubscription, .gemini])
    func completedAttemptsPreserveTheirProviderVisibleInitialPrefixes(provider: BrainProvider) async throws {
        let script = try [
            call("load_skill", id: "a1_skill", arguments: ["name": "coding"], provider: provider),
            call("load_tool", id: "a1_tool", arguments: ["name": "search_references"], provider: provider),
            call("call_tool", id: "a1_search", arguments: [
                "name": "search_references", "arguments": "{\"query\":\"ledger idempotency\"}"], provider: provider),
            speak("a1_speak", provider: provider), speak("a2_speak", provider: provider),
            call("stay_silent", id: "a3_silent", arguments: [:], provider: provider),
            speak("a4_speak", provider: provider),
            call("load_skill", id: "a5_skill", arguments: ["name": "coding"], provider: provider),
            call("load_tool", id: "a5_tool", arguments: ["name": "search_references"], provider: provider),
            speak("a5_speak", provider: provider), speak("a6_speak", provider: provider),
            call("stay_silent", id: "a7_silent", arguments: [:], provider: provider),
            speak("a8_speak", provider: provider),
        ]
        let transport = ContextCacheTransport(script: script.map { .response($0) })
        let transcript = RollingTranscript()
        let overlay = FakeOverlay()
        let search = FakeDocumentSession(results: [
            referenceHit(name: "synthetic-ledger.md",
                  text: "Commit the deduplicated effect and checkpoint atomically.")])
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [.init(target: target(provider), brain: accessor(transport, provider: provider))]),
            screen: UnavailableScreen(), overlay: overlay, clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in }, capabilities: capabilities, documents: search,
            sessionContext: try SessionContext(documentCatalog: .bounded([.init(documentID: search.documentID, name: "synthetic-ledger.md", format: "md")])))
        let triggers: [TriggerReason] = [
            .turnEnd, .turnEnd, .silence(secondsQuiet: 3), .manualCode,
            .turnEnd, .turnEnd, .silence(secondsQuiet: 5), .manualHint,
        ]
        var outcomes: [TurnOutcome] = []
        for (index, trigger) in triggers.enumerated() {
            transcript.append(.init(speaker: .them,
                text: "Ledger question \(index + 1): explain checkpoint ownership when a duplicate arrives after a worker transfer.",
                at: Double(100 + index)))
            outcomes.append(await driver.handleTrigger(trigger))
        }
        #expect(outcomes == [.spoke, .spoke, .silentByModel, .spoke,
                             .spoke, .spoke, .silentByModel, .spoke])
        #expect(overlay.rendered.count == 6)
        #expect(search.queries == ["ledger idempotency"])
        let captured = await transport.captured
        #expect(captured.allSatisfy { $0.contextRevision == 0 && $0.contextRewriteReason == nil })
        let requests = try captured.map { try object($0.body) }
        let initialIndices = captured.indices.filter { captured[$0].phase == .initial }
        #expect(initialIndices.count == 8)
        let initialRequests = initialIndices.map { requests[$0] }
        #expect(try prefixResults(initialRequests, provider: provider) == Array(repeating: true, count: 7))
        let instructionsKey = switch provider {
        case .claudeSubscription: "system"
        case .gemini: "system_instruction"
        default: "instructions"
        }
        let instructions = try requests.map { try canonical(#require($0[instructionsKey])) }
        let tools = try requests.map { try canonical(#require($0["tools"])) }
        #expect(Set(instructions).count == 1)
        #expect(Set(tools).count == 1)
        #expect(!requests.contains { request in
            items(request, provider: provider).contains { item in
                (item["text"] as? String)?.hasPrefix("Session state:") == true ||
                    (item["content"] as? [[String: Any]])?.contains {
                        ($0["text"] as? String)?.hasPrefix("Session state:") == true
                    } == true
            }
        })
        let skillDuplicate = try #require(captured.first { $0.attempt == 5 && $0.sequence == 2 })
        let skillOutput = try output("a5_skill", in: object(skillDuplicate.body), provider: provider)
        #expect(skillOutput == JarvisPrompts.Coach.loadSkillAlreadyLoaded("coding"))
        #expect(!skillOutput.contains("Ledger invariants"))
        let toolDuplicate = try #require(captured.first { $0.attempt == 5 && $0.sequence == 3 })
        #expect(try output("a5_tool", in: object(toolDuplicate.body), provider: provider)
            == JarvisPrompts.Coach.loadToolAlreadyLoaded("search_references"))
        for request in initialRequests.dropFirst() {
            #expect(try output("a1_skill", in: request, provider: provider).contains(codingSkill.body))
            #expect(try output("a1_tool", in: request, provider: provider).contains(searchReferencesTool.parametersJSON))
        }
        let withMovingFooter = try initialRequests.map { try addingTransientFooter(to: $0, provider: provider) }
        #expect(try prefixResults(withMovingFooter, provider: provider) == Array(repeating: false, count: 7))
    }

    @Test(arguments: [BrainProvider.openAI, .claudeSubscription, .gemini], [false, true])
    func failedOrCancelledLoadsNeverBecomeCommittedState(provider: BrainProvider, cancel: Bool) async throws {
        let transport = ContextCacheTransport(script: [
            .response(try call("load_skill", id: "aborted_skill", arguments: ["name": "coding"], provider: provider)),
            .response(try call("load_tool", id: "aborted_tool", arguments: ["name": "search_references"], provider: provider)),
            cancel ? .cancel : .fail,
            .response(try call("load_skill", id: "retry_skill", arguments: ["name": "coding"], provider: provider)),
            .response(try call("load_tool", id: "retry_tool", arguments: ["name": "search_references"], provider: provider)),
            .response(try speak("retry_speak", provider: provider)),
        ])
        let runner = makeRunner()
        let brain = accessor(transport, provider: provider)
        let first = await run(runner, brain: brain, provider: provider)
        if cancel {
            guard case .cancelled = first else { Issue.record("expected cancellation"); return }
        } else {
            guard case .failed = first else { Issue.record("expected failed attempt"); return }
        }
        guard case .completed(.spoke) = await run(runner, brain: brain, provider: provider) else {
            Issue.record("expected retry to complete"); return
        }
        let requests = await transport.captured
        let retryInitial = try #require(requests.first { $0.attempt == 2 && $0.phase == .initial })
        let initialJSON = String(decoding: retryInitial.body, as: UTF8.self)
        #expect(!initialJSON.contains("aborted_skill"))
        #expect(!initialJSON.contains("aborted_tool"))
        #expect(!initialJSON.contains("Ledger invariants"))
        let retrySkill = try #require(requests.first { $0.attempt == 2 && $0.sequence == 2 })
        #expect(try output("retry_skill", in: object(retrySkill.body), provider: provider).contains(codingSkill.body))
        let retryTool = try #require(requests.first { $0.attempt == 2 && $0.sequence == 3 })
        #expect(try output("retry_tool", in: object(retryTool.body), provider: provider).contains(searchReferencesTool.parametersJSON))
    }

    @Test(arguments: [BrainProvider.openAI, .claudeSubscription, .gemini])
    func rawReasoningReplaysWithinTheAttemptAndNormalizesAtCommit(provider: BrainProvider) async throws {
        let reasoning: [String: Any] = switch provider {
        case .claudeSubscription: ["type": "thinking", "thinking": "synthetic reasoning", "signature": "synthetic-signature"]
        case .gemini: ["type": "thought", "signature": "synthetic-signature"]
        default: ["type": "reasoning", "id": "rs_synthetic", "encrypted_content": "synthetic-signature", "summary": []]
        }
        let first = try call("load_skill", id: "raw_skill", arguments: ["name": "coding"], provider: provider,
                             preceding: [reasoning], itemID: "fc_synthetic")
        let transport = ContextCacheTransport(script: [.response(first),
            .response(try speak("raw_speak", provider: provider)),
            .response(try speak("next_speak", provider: provider))])
        let runner = makeRunner()
        let brain = accessor(transport, provider: provider)
        guard case .completed = await run(runner, brain: brain, provider: provider),
              case .completed = await run(runner, brain: brain, provider: provider) else {
            Issue.record("expected completed attempts"); return
        }
        let requests = await transport.captured
        #expect(requests.count == 3)
        let continuation = try object(requests[1].body)
        let next = try object(requests[2].body)
        let replay = items(continuation, provider: provider)
        let echoed = try #require(replay.first { $0["type"] as? String == reasoning["type"] as? String })
        #expect(try canonical(echoed) == canonical(reasoning))
        #expect(!String(decoding: requests[2].body, as: UTF8.self).contains("synthetic-signature"))
        #expect(try output("raw_skill", in: next, provider: provider).contains(codingSkill.body))
        if provider == .openAI {
            #expect(replay.contains { $0["id"] as? String == "fc_synthetic" })
            #expect(!items(next, provider: provider).contains { $0["id"] as? String == "fc_synthetic" })
        }
        #expect(try prefixResults([continuation, next], provider: provider) == [false])
        #expect(try prefixResults([object(requests[0].body), next], provider: provider) == [true])
    }

    @Test(arguments: [BrainProvider.openAI, .claudeSubscription, .gemini])
    func intentionalScreenAndCompactionResetsAllowSubsequentReuse(provider: BrainProvider) async throws {
        let history = CoachHistory()
        let load = RawToolCall(id: "retained_skill", name: "load_skill", argumentsJSON: "{\"name\":\"coding\"}")
        history.commit([
            .user("Ledger design: " + String(repeating: "deduplicate events before checkpointing. ", count: 20)),
            .assistantToolCalls([load]),
            .init(role: .tool, text: JarvisPrompts.Coach.loadSkillResult(codingSkill), toolCallId: load.id),
            .user("\(JarvisPrompts.Coach.screenTextHeader)\nold_code"),
        ])
        let transport = ContextCacheTransport(script: [.response(try speak("reset_reply", provider: provider))])
        let brain = accessor(transport, provider: provider)
        func encodeSnapshot() async throws {
            _ = try await brain.respond(messages: [.system("Immutable instructions.")] + history.snapshot(),
                                        tools: capabilities.tools, toolChoice: .required)
        }
        try await encodeSnapshot()
        let stale = try #require(history.compactionPrefix(fraction: 0.99))
        history.commit([.user("\(JarvisPrompts.Coach.screenTextHeader)\nnew_code")])
        #expect(!history.compact(prefixCount: stale.count, summary: "stale", revision: stale.revision))
        try await encodeSnapshot()
        let fresh = try #require(history.compactionPrefix(fraction: 0.99))
        #expect(history.compact(prefixCount: fresh.count, summary: "Ledger ownership summary.", revision: fresh.revision))
        #expect(history.snapshot().contains { $0.toolCallId == "retained_skill" && $0.text?.contains(codingSkill.body) == true })
        try await encodeSnapshot()
        history.commit([.user("Next question after the intentional reset.")])
        try await encodeSnapshot()
        let requests = try await transport.captured.map { try object($0.body) }
        #expect(try prefixResults(requests, provider: provider) == [false, false, true])
        #expect(!String(decoding: try canonical(requests[1]), as: UTF8.self).contains("old_code"))
    }

    private func target(_ provider: BrainProvider) -> BrainTarget {
        let modelID = switch provider {
        case .claudeSubscription: "claude-sonnet-5-5"
        case .gemini: "gemini-3.8-flash"
        default: "gpt-6.1-sol"
        }
        return .init(provider: provider, modelID: modelID)
    }

    private func accessor(_ transport: ContextCacheTransport, provider: BrainProvider) -> BrainAccessor {
        BrainAccessor(provider: provider, apiKey: "synthetic-key", model: target(provider).modelID,
                      send: { request in try await transport.send(request, context: CoachingRequestAttribution.current) })
    }

    private func makeRunner() -> CoachAttemptRunner {
        CoachAttemptRunner(config: .default, transcript: RollingTranscript(), screen: UnavailableScreen(),
            overlay: FakeOverlay(), clock: ManualClock(now: 100), sessionStart: 0,
            coachingAttempts: nil, activity: nil, ledger: CoachTranscriptLedger(), capabilities: capabilities)
    }

    private func run(_ runner: CoachAttemptRunner, brain: BrainClient, provider: BrainProvider) async -> CoachAttemptRunner.AttemptResult {
        var work = CoachAttemptRunner.PendingCoachingWork(reason: .turnEnd)
        work.referencesObservation = .user("Pending ledger question.")
        return await runner.runAttempt(work, using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target(provider), brain: brain, summarizer: nil, onSelected: nil, documents: nil)).result
    }

    private func speak(_ id: String, provider: BrainProvider) throws -> Data {
        try call("speak", id: id, arguments: ["hint": "State the ledger invariant before the implementation."], provider: provider)
    }

    private func call(_ name: String, id: String, arguments: [String: Any], provider: BrainProvider,
                      preceding: [[String: Any]] = [], itemID: String? = nil) throws -> Data {
        switch provider {
        case .claudeSubscription:
            return try canonical(["stop_reason": "tool_use", "content": preceding + [
                ["type": "tool_use", "id": id, "name": name, "input": arguments]]])
        case .gemini:
            let thought = preceding.isEmpty ? [["type": "thought", "signature": "fixture-signature"]] : preceding
            return try canonical(["status": "requires_action", "steps": thought + [
                ["type": "function_call", "id": id, "name": name, "arguments": arguments]]])
        default:
            var call: [String: Any] = ["type": "function_call", "call_id": id, "name": name,
                                      "arguments": String(decoding: try canonical(arguments), as: UTF8.self)]
            if let itemID { call["id"] = itemID }
            return try canonical(["status": "completed", "output": preceding + [call]])
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func items(_ request: [String: Any], provider: BrainProvider) -> [[String: Any]] {
        if provider == .claudeSubscription {
            return (request["messages"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        }
        return request["input"] as? [[String: Any]] ?? []
    }

    private func prefixResults(_ requests: [[String: Any]], provider: BrainProvider) throws -> [Bool] {
        let inputs = try requests.map { request -> [Data] in
            if provider == .claudeSubscription {
                return try #require(request["messages"] as? [[String: Any]]).flatMap { turn in
                    try #require(turn["content"] as? [[String: Any]]).map { block in
                        try canonical(["role": #require(turn["role"]), "block": block])
                    }
                }
            }
            return try #require(request["input"] as? [[String: Any]]).map(canonical)
        }
        return zip(inputs, inputs.dropFirst()).map { previous, next in
            next.count >= previous.count && Array(next.prefix(previous.count)) == previous
        }
    }

    private func output(_ stem: String, in request: [String: Any], provider: BrainProvider) throws -> String {
        let result = items(request, provider: provider).first { item in
            let id = item["call_id"] as? String ?? item["tool_use_id"] as? String ?? ""
            let isResult = ["function_call_output", "function_result", "tool_result"].contains(item["type"] as? String ?? "")
            return isResult && (id == stem || id.hasPrefix(stem + "_"))
        }
        return try #require(result?[provider == .claudeSubscription ? "content" : provider == .gemini ? "result" : "output"] as? String)
    }

    private func addingTransientFooter(to request: [String: Any], provider: BrainProvider) throws -> [String: Any] {
        var request = request
        if provider == .claudeSubscription {
            var messages = try #require(request["messages"] as? [[String: Any]])
            var content = try #require(messages[messages.count - 1]["content"] as? [[String: Any]])
            content.append(["type": "text", "text": "Session state: transient loaded capabilities."])
            messages[messages.count - 1]["content"] = content
            request["messages"] = messages
        } else {
            var input = try #require(request["input"] as? [[String: Any]])
            input.append(provider == .gemini
                ? ["type": "user_input", "content": [["type": "text", "text": "Session state: transient loaded capabilities."]]]
                : ["role": "user", "content": [["type": "input_text", "text": "Session state: transient loaded capabilities."]]])
            request["input"] = input
        }
        return request
    }
}

private actor ContextCacheTransport {
    enum Step: Sendable { case response(Data), cancel, fail }
    struct Capture: Sendable {
        let body: Data
        let attempt: Int
        let sequence: Int
        let phase: CoachingAttemptAuditEvent.RequestPhase?
        let contextRevision: UInt?
        let contextRewriteReason: CoachingContextRewriteReason?
    }
    private let script: [Step]
    private(set) var captured: [Capture] = []

    init(script: [Step]) { self.script = script }

    func send(_ request: URLRequest, context: CoachingRequestContext?) throws
        -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse?) {
        let index = captured.count
        captured.append(Capture(body: request.httpBody ?? Data(), attempt: context?.attemptID ?? 0,
            sequence: context?.sequence ?? 0, phase: context?.phase,
            contextRevision: context?.contextRevision, contextRewriteReason: context?.contextRewriteReason))
        switch script[min(index, script.count - 1)] {
        case .cancel: throw CancellationError()
        case .fail: throw URLError(.networkConnectionLost)
        case .response(let data):
            return (AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            }, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        }
    }
}
