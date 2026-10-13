import Foundation
import Testing
@testable import JarvisCore
@testable import JarvisBrainProviders

@Suite struct ProviderCacheObserverTests {
    private let wire = ResponsesWireFormat(
        model: "gpt-6.1-sol", reasoningEffort: "low", maxOutputTokens: 2_048, store: true, stream: false)

    private func context(_ attempt: Int, phase: CoachingAttemptAuditEvent.RequestPhase = .initial,
                         revision: UInt = 0, reason: CoachingContextRewriteReason? = nil) -> CoachingRequestContext {
        CoachingRequestContext(attemptID: attempt, trigger: "turn_end", sourceTrigger: "turn_end",
                               phase: phase, sequence: 1, contextRevision: revision, contextRewriteReason: reason)
    }

    private func request(_ messages: [ChatMessage], tools: [ToolDef] = coachTools) throws -> Data {
        try wire.encode(messages: [.system("Synthetic private coaching instructions")] + messages,
                        tools: tools, toolChoice: .required)
    }

    private func encoder(_ api: String) -> any BrainWireFormat {
        switch api {
        case "messages":
            MessagesWireFormat(model: "claude-sonnet-5-5", reasoningEffort: "low", maxOutputTokens: 2_048, stream: false)
        case "interactions":
            InteractionsWireFormat(model: "gemini-3.8-flash", reasoningEffort: "low", maxOutputTokens: 2_048)
        default:
            wire
        }
    }

    @Test func completedInitialRequestsKeepTheirCheckpointAcrossContinuations() throws {
        let observer = ProviderCacheObserver()
        let first: [ChatMessage] = [.user("Synthetic prep catalog"), .user("question one")]
        let initial = try #require(observer.observe(request: request(first), response: nil, context: context(1)))
        #expect(initial.requestPrefixPreserved == nil)
        let call = RawToolCall(id: "load", name: "load_skill", argumentsJSON: #"{"skill":"coding"}"#)
        let continuation = first + [.rawItems([
            #"{"type":"reasoning","id":"rs_1","encrypted_content":"synthetic opaque payload"}"#,
            #"{"type":"function_call","id":"fc_1","call_id":"load","name":"load_skill","arguments":"{\"skill\":\"coding\"}"}"#,
        ], calls: [call]), ChatMessage(role: .tool, text: "Durable skill guidance", toolCallId: "load")]
        let middle = try #require(observer.observe(request: request(continuation), response: nil,
                                                   context: context(1, phase: .loadSkillContinuation)))
        #expect(middle.requestPrefixPreserved == true)
        let next = first + [.assistantToolCalls([call]),
                            ChatMessage(role: .tool, text: "Durable skill guidance", toolCallId: "load"),
                            .user("question two")]
        let final = try #require(observer.observe(request: request(next), response: nil, context: context(2)))
        #expect(final.inputPrefixPreserved == true)
        #expect(final.requestPrefixPreserved == true)
        #expect(final.previousInputItemCount == initial.inputItemCount)
        #expect(final.firstChangedSegment == nil)
    }

    @Test(arguments: ["responses", "messages", "interactions"])
    func changingManualToolChoiceKeepsTheReusablePrefix(_ api: String) throws {
        let observer = ProviderCacheObserver()
        let encoder = encoder(api)
        let messages: [ChatMessage] = [.system("Coach"), .user("question")]
        let first = try encoder.encode(messages: messages, tools: coachTools, toolChoice: .required)
        let choice: ToolChoice = api == "interactions" ? .force(speakToolName) : .allowed([speakToolName])
        let next = try encoder.encode(messages: messages + [.user("manual hint")], tools: coachTools, toolChoice: choice)
        _ = observer.observe(request: first, response: nil, context: context(1))
        #expect(observer.observe(request: next, response: nil, context: context(2))?.requestPrefixPreserved == true)
    }

    @Test(arguments: ["responses", "messages", "interactions"], ["inserted", "removed", "reordered", "mutated"])
    func earlierInputChangesBreakTheActualEncodedPrefix(_ api: String, _ mutation: String) throws {
        let observer = ProviderCacheObserver()
        let encoder = encoder(api)
        let original: [ChatMessage] = [.user("catalog"), .user("earlier question"), .user("later question")]
        var changed = original
        switch mutation {
        case "inserted": changed.insert(.user("inserted earlier question"), at: 1)
        case "removed": changed.remove(at: 1)
        case "reordered": changed.swapAt(1, 2)
        default: changed[1] = .user("mutated earlier question")
        }
        func encode(_ messages: [ChatMessage]) throws -> Data {
            try encoder.encode(messages: [.system("Coach")] + messages, tools: coachTools, toolChoice: .required)
        }
        _ = observer.observe(request: try encode(original), response: nil, context: context(1))
        let observation = try #require(observer.observe(request: encode(changed), response: nil, context: context(2)))
        #expect(observation.inputPrefixPreserved == false)
        #expect(observation.requestPrefixPreserved == false)
        #expect(observation.firstChangedSegment == .input)
        #expect(observation.firstChangedInputIndex == 1)
        #expect(!observation.inputComparisonTruncated)
    }

    @Test func withinAttemptReasoningMutationReportsTheChangedRawItem() throws {
        let observer = ProviderCacheObserver()
        let call = RawToolCall(id: "load", name: "load_skill", argumentsJSON: "{}")
        let initial: [ChatMessage] = [.user("question")]
        _ = observer.observe(request: try request(initial), response: nil, context: context(1))
        func continuation(_ encrypted: String) throws -> Data {
            try request(initial + [.rawItems([
                "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"\(encrypted)\"}",
                #"{"type":"function_call","id":"fc_1","call_id":"load","name":"load_skill","arguments":"{}"}"#,
            ], calls: [call]), ChatMessage(role: .tool, text: "guidance", toolCallId: "load")])
        }
        let first = try #require(observer.observe(request: continuation("original"), response: nil,
                                                  context: context(1, phase: .loadSkillContinuation)))
        #expect(first.requestPrefixPreserved == true)
        let changed = try #require(observer.observe(request: continuation("changed"), response: nil,
                                                    context: context(1, phase: .loadSkillContinuation)))
        #expect(changed.requestPrefixPreserved == false)
        #expect(changed.firstChangedSegment == .input)
        #expect(changed.firstChangedInputIndex == 1)
    }

    @Test func movingFooterReportsItsFirstChangedInput() throws {
        let observer = ProviderCacheObserver()
        let first: [ChatMessage] = [.user("question one"), .user("Session state: coding loaded")]
        _ = observer.observe(request: try request(first), response: nil, context: context(1))
        let call = RawToolCall(id: "speak", name: "speak", argumentsJSON: "{}")
        let next: [ChatMessage] = [.user("question one"), .assistantToolCalls([call]),
                                  ChatMessage(role: .tool, text: "delivered", toolCallId: "speak"),
                                  .user("question two"), .user("Session state: coding loaded")]
        let observation = try #require(observer.observe(request: request(next), response: nil, context: context(2)))
        #expect(observation.inputPrefixPreserved == false)
        #expect(observation.requestPrefixPreserved == false)
        #expect(observation.firstChangedSegment == .input)
        #expect(observation.firstChangedInputIndex == 1)
    }

    @Test func declaredRewriteStillReportsAChangedPrefixThenRecovers() throws {
        let observer = ProviderCacheObserver()
        _ = observer.observe(request: try request([.user("old history")]), response: nil, context: context(1))
        let reset = try #require(observer.observe(request: request([.user("compact summary")]), response: nil,
                                                 context: context(2, revision: 1, reason: .compaction)))
        #expect(reset.requestPrefixPreserved == false)
        #expect(reset.firstChangedSegment == .input)
        let next = try #require(observer.observe(request: request([.user("compact summary"), .user("new question")]),
                                                response: nil, context: context(3, revision: 1, reason: .compaction)))
        #expect(next.requestPrefixPreserved == true)
    }

    @Test func toolsSettingsAndInstructionsHaveDistinctChangeSegments() throws {
        let base = try request([.user("question")])
        for (key, value, expected) in [
            ("instructions", "new instructions" as Any, BrainCacheObservation.Segment.instructions),
            ("tools", [] as Any, BrainCacheObservation.Segment.tools),
            ("reasoning", ["effort": "high"] as Any, BrainCacheObservation.Segment.settings),
            ("model", "different-model" as Any, BrainCacheObservation.Segment.model),
        ] {
            let observer = ProviderCacheObserver()
            _ = observer.observe(request: base, response: nil, context: context(1))
            var object = try #require(try JSONSerialization.jsonObject(with: base) as? [String: Any])
            object[key] = value
            let next = try #require(observer.observe(request: JSONSerialization.data(withJSONObject: object),
                                                    response: nil, context: context(2)))
            #expect(next.firstChangedSegment == expected)
            #expect(next.inputPrefixPreserved == true)
            #expect(next.requestPrefixPreserved == false)
        }
    }

    @Test func longHistoryDetectsChangesBeyondTheBoundedItemTable() throws {
        let observer = ProviderCacheObserver()
        let first = (0..<300).map { ChatMessage.user("synthetic item \($0)") }
        _ = observer.observe(request: try request(first), response: nil, context: context(1))
        var changed = first
        changed[280] = .user("changed after the fingerprint table")
        let observation = try #require(observer.observe(request: request(changed), response: nil, context: context(2)))
        #expect(observation.inputPrefixPreserved == false)
        #expect(observation.firstChangedSegment == .input)
        #expect(observation.firstChangedInputIndex == nil)
        #expect(observation.inputComparisonTruncated)
        #expect(observation.fingerprintLimit == 256)
        let appended = changed + [.user("next")]
        #expect(observer.observe(request: try request(appended), response: nil, context: context(3))?.inputPrefixPreserved == true)
    }

    @Test func messagesTurnGrowthPreservesEarlierOrderedBlocks() throws {
        let observer = ProviderCacheObserver()
        let messages = MessagesWireFormat(model: "claude-sonnet-5-5", reasoningEffort: "low", maxOutputTokens: 2_048, stream: false)
        let first = try messages.encode(messages: [.system("Coach"), .user("catalog"), .user("question")], tools: coachTools, toolChoice: .required)
        _ = observer.observe(request: first, response: nil, context: context(1))
        let next = try messages.encode(messages: [.system("Coach"), .user("catalog"), .user("question"), .user("next")], tools: coachTools, toolChoice: .required)
        let observation = try #require(observer.observe(request: next, response: nil, context: context(2)))
        #expect(observation.inputPrefixPreserved == true)
        #expect(observation.requestPrefixPreserved == true)
    }

    @Test func invalidBodiesAndMissingUsageDoNotProduceZeroCounters() throws {
        let observer = ProviderCacheObserver()
        #expect(observer.observe(request: Data("not json".utf8), response: nil, context: context(1)) == nil)
        let observation = try #require(observer.observe(request: request([.user("question")]),
                                                       response: Data("not json".utf8), context: context(1)))
        #expect(observation.usage == nil)
    }

    @Test func workerSerializesOnlyRedactedCacheMetadataWithOptionalUsage() async throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = await FileSessionAudit.readyForTesting(directory: directory)
        let observer = ProviderCacheObserver()
        let first = try request([.user("SYNTHETIC_PRIVATE_TRANSCRIPT")])
        let response = Data(#"{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":60,"cache_write_tokens":20},"output_tokens":5}}"#.utf8)
        for (index, body) in [first, try request([.user("changed synthetic history")])].enumerated() {
            audit.record(BrainTrafficAuditEvent(
                tag: "coach", provider: .openAI, request: body, response: index == 0 ? response : nil,
                status: 200, latencyMs: 1, error: nil, phases: nil, kind: .providerCall,
                requestContext: context(index + 1, revision: UInt(index), reason: index == 1 ? .compaction : nil),
                cacheObserver: observer, date: Date()))
        }
        _ = await audit.closeForTesting()
        let data = try Data(contentsOf: directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename))
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let cache = try #require(rows.first?["cache"] as? [String: Any])
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: cache), as: UTF8.self)
        #expect(!serialized.contains("SYNTHETIC_PRIVATE_TRANSCRIPT"))
        #expect(!serialized.contains("Synthetic private coaching instructions"))
        #expect(cache["scope"] as? String == "client_wire")
        #expect((cache["input_sha256"] as? String)?.count == 64)
        let usage = try #require(cache["usage"] as? [String: Any])
        #expect(usage["total_input"] as? Int == 100)
        #expect(usage["cache_read"] as? Int == 60)
        #expect(usage["cache_write"] as? Int == 20)
        #expect(usage["uncached_input"] as? Int == 20)
        #expect(usage["output"] as? Int == 5)
        let next = try #require(rows.last?["cache"] as? [String: Any])
        #expect(next["request_prefix_preserved"] as? Bool == false)
        #expect(next["first_changed_segment"] as? String == "input")
        #expect(next["usage"] == nil)
        let attribution = try #require(rows.last?["coach_attempt"] as? [String: Any])
        #expect(attribution["context_revision"] as? Int == 1)
        #expect(attribution["context_rewrite_reason"] as? String == "compaction")
    }
}
