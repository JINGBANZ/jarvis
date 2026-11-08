import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct ResponsesWireFormatTests {
    private func body(_ messages: [ChatMessage], store: Bool = true) throws -> [String: Any] {
        let wire = ResponsesWireFormat(
            model: "gpt-5.5", reasoningEffort: "low", maxOutputTokens: 2_048, store: store, stream: false)
        let data = try wire.encode(messages: messages, tools: [], toolChoice: .auto)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func kinds(_ body: [String: Any]) -> [String] {
        (body["input"] as? [[String: Any]] ?? []).map {
            ($0["type"] as? String) ?? ($0["role"] as? String) ?? "?"
        }
    }

    @Test func toolDeclarationsCarryGuidanceAndRemainStableAcrossHistory() throws {
        let wire = ResponsesWireFormat(model: "gpt-5.5", reasoningEffort: "low", maxOutputTokens: 2_048, store: false, stream: false)
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: SkillCatalog.bundled())
        let system = JarvisPrompts.Coach.system(capabilities: capabilities)
        let call = RawToolCall(id: "load", name: "load_tool", argumentsJSON: "{}")
        let histories: [[ChatMessage]] = [
            [.user("first request")],
            [.user("first request"), .assistantToolCalls([call]),
             ChatMessage(role: .tool, text: "loaded guidance", toolCallId: "load"), .user("next request")],
        ]
        var declarations: [Data] = []
        for history in histories {
            let data = try wire.encode(messages: [.system(system)] + history,
                                       tools: capabilities.tools, toolChoice: .required)
            let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tools = try #require(payload["tools"] as? [[String: Any]])
            let speak = try #require(tools.first { $0["name"] as? String == "speak" })
            #expect(speak["description"] as? String == speakTool.description + "\n\n" + speakTool.guidance)
            let schema = try #require(speak["parameters"] as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            let hint = try #require(properties["hint"]?["description"] as? String)
            let detail = try #require(properties["detail"]?["description"] as? String)
            #expect(hint == "The short reply displayed to the user.")
            #expect(detail == "Optional Markdown displayed below the hint.")
            #expect((speak["description"] as? String ?? "").contains("an explanation request is not required"))
            #expect((speak["description"] as? String ?? "").contains("# Hint"))
            #expect((speak["description"] as? String ?? "").contains("# Detail"))
            let capture = try #require(tools.first { $0["name"] as? String == "capture_screen" })
            #expect(capture["description"] as? String == captureScreenTool.description + "\n\n" + captureScreenTool.guidance)
            #expect(!tools.contains { $0["name"] as? String == "search_references" })
            #expect(!system.contains(speakTool.guidance))
            #expect(!system.contains(searchReferencesTool.guidance))
            declarations.append(try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]))
        }
        #expect(declarations[0] == declarations[1])
    }

    @Test(arguments: [false, true])
    func metadataPrefixSurvivesChangingHistoryAndToolContinuations(store: Bool) throws {
        let catalog = #"Untrusted filenames: [{"documentID":"stable-id","sourceDisplayName":"notes.md"}]"#
        let call = RawToolCall(id: "read", name: "read_reference", argumentsJSON: "{}")
        let tails: [[ChatMessage]] = [
            [.user("first request")],
            [.user("first request"), .assistantToolCalls([call]),
             ChatMessage(role: .tool, text: "page text", toolCallId: "read")],
            [.user("first request"), ChatMessage(role: .assistant, text: "previous answer"),
             .user("next request")],
        ]
        var encodedPrefixes: [Data] = []
        for tail in tails {
            let payload = try body([.system("Coaching instructions"), .user(catalog)] + tail, store: store)
            let input = try #require(payload["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            let prefix = try #require(content.first)
            #expect(payload["instructions"] as? String == "Coaching instructions")
            #expect(prefix["text"] as? String == catalog)
            encodedPrefixes.append(try JSONSerialization.data(withJSONObject: prefix, options: [.sortedKeys]))
            let text = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            #expect(text.components(separatedBy: "stable-id").count == 2)
        }
        #expect(Set(encodedPrefixes).count == 1)
    }

    @Test func assistantMessagesReplayRawItemsOrCallsOrText() throws {
        let call = RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")
        let raw = try body([.rawItems(
            [#"{"type":"reasoning","id":"rs_1"}"#,
             #"{"type":"function_call","id":"fc_1","call_id":"c1","name":"capture_screen","arguments":"{}"}"#],
            calls: [call])])
        #expect(kinds(raw) == ["reasoning", "function_call"])
        #expect(kinds(try body([.assistantToolCalls([call])])) == ["function_call"])
        #expect(kinds(try body([ChatMessage(role: .assistant, text: "prose")])) == ["assistant"])
    }

    @Test func storeAndCacheKeyAreSent() throws {
        #expect(try body([.user("hi")])["store"] as? Bool == true)
        #expect(try body([.user("hi")], store: false)["store"] as? Bool == false)
        #expect(try body([.user("hi")])["prompt_cache_key"] as? String == "jarvis-coach-v1")
        #expect(try body([.user("hi")])["parallel_tool_calls"] as? Bool == false)
    }

    /// Models write arguments in schema order, so `hint` must reach the wire before `detail`.
    @Test func toolSchemasKeepTheirAuthoredKeyOrder() throws {
        let wire = ResponsesWireFormat(
            model: "gpt-5.5", reasoningEffort: "low", maxOutputTokens: 2_048, store: true, stream: false)
        let tools = coachTools
        let data = try wire.encode(messages: [.user("hi")], tools: tools, toolChoice: .auto)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(speakTool.parametersJSON))
        let hint = try #require(text.range(of: #""hint""#))
        let detail = try #require(text.range(of: #""detail""#))
        #expect(hint.lowerBound < detail.lowerBound)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let declared = try #require(body["tools"] as? [[String: Any]])
        #expect(declared.compactMap { $0["name"] as? String } == tools.map(\.name))
        let speak = declared[1]["parameters"] as? [String: Any]
        #expect(speak?["required"] as? [String] == ["hint", "detail"])
    }
}
