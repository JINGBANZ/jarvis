import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct ResponsesWireFormatTests {
    private func body(_ messages: [ChatMessage], store: Bool = true) throws -> [String: Any] {
        let wire = ResponsesWireFormat(
            model: "gpt-5.5", reasoningEffort: "low", maxOutputTokens: 2_048, store: store)
        let data = try wire.encode(messages: messages, tools: [], toolChoice: .auto)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func kinds(_ body: [String: Any]) -> [String] {
        (body["input"] as? [[String: Any]] ?? []).map {
            ($0["type"] as? String) ?? ($0["role"] as? String) ?? "?"
        }
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

    /// Models write arguments in schema order, so `lines` must reach the wire before `detail`.
    @Test func toolSchemasKeepTheirAuthoredKeyOrder() throws {
        let wire = ResponsesWireFormat(
            model: "gpt-5.5", reasoningEffort: "low", maxOutputTokens: 2_048, store: true)
        let tools = coachTools
        let data = try wire.encode(messages: [.user("hi")], tools: tools, toolChoice: .auto)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(speakTool.parametersJSON))
        let lines = try #require(text.range(of: #""lines""#))
        let detail = try #require(text.range(of: #""detail""#))
        #expect(lines.lowerBound < detail.lowerBound)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let declared = try #require(body["tools"] as? [[String: Any]])
        #expect(declared.compactMap { $0["name"] as? String } == tools.map(\.name))
        let speak = declared[1]["parameters"] as? [String: Any]
        #expect(speak?["required"] as? [String] == ["lines", "detail"])
    }
}
