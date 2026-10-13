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

    @Test func metadataPrefixSurvivesChangingHistoryAndToolContinuations() throws {
        let catalog = #"Untrusted filenames: [{"documentID":"stable-id","sourceDisplayName":"notes.md"}]"#
        let call = RawToolCall(id: "read", name: "read_prep_note", argumentsJSON: "{}")
        let tails: [[ChatMessage]] = [
            [.user("first request")],
            [.user("first request"), .assistantToolCalls([call]),
             ChatMessage(role: .tool, text: "page text", toolCallId: "read")],
            [.user("first request"), ChatMessage(role: .assistant, text: "previous answer"),
             .user("next request")],
        ]
        var encodedPrefixes: [Data] = []
        for tail in tails {
            let payload = try body([.system("Coaching instructions"), .user(catalog)] + tail)
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
