import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct RecordedExchangeTests {
    func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func responsesRecordReadsIntoTheNeutralView() {
        let request = json(#"""
        {"model":"gpt-5.5","reasoning":{"effort":"low"},"max_output_tokens":2048,
         "tool_choice":{"type":"allowed_tools","mode":"required","tools":[{"type":"function","name":"speak"}]},
         "instructions":"You are Jarvis.",
         "tools":[{"type":"function","name":"speak","parameters":{"type":"object","properties":{"lines":{},"detail":{}}}}],
         "input":[{"role":"user","content":[{"type":"input_text","text":"hi"},{"type":"input_image","image_url":"[base64 image omitted]"}]},
                  {"type":"reasoning","id":"rs_1"},
                  {"type":"function_call","call_id":"c1","name":"capture_screen","arguments":"{}"},
                  {"type":"function_call_output","call_id":"c1","output":"captured"}]}
        """#)
        let response = json(#"""
        {"status":"completed","output":[{"type":"reasoning","id":"rs_2"},
          {"type":"function_call","call_id":"c2","name":"speak","arguments":"{\"lines\":[\"Hi\"],\"detail\":\"More.\"}"},
          {"type":"message","content":[{"type":"output_text","text":"prose"}]}],
         "usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":4},"output_tokens":7}}
        """#)
        let exchange = RecordedExchange.read(request: request, response: response)
        #expect(exchange.model == "gpt-5.5")
        #expect(exchange.parameters.map(\.name) == ["reasoning", "max_output_tokens", "tool_choice"])
        #expect(exchange.parameters[1].value == "2048")
        #expect(exchange.instructions == "You are Jarvis.")
        #expect(exchange.toolNames == ["speak"])
        #expect(exchange.toolCount == 1)
        #expect(exchange.speakParameters == ["detail", "lines"])
        #expect(exchange.toolChoiceType == "allowed_tools")
        #expect(exchange.input == [
            .message(role: "user", parts: ["hi", "[base64 image omitted]"]),
            .reasoning(characters: RecordedExchange.canonical(["type": "reasoning", "id": "rs_1"]).count),
            .call(.init(id: "c1", name: "capture_screen", arguments: "{}")),
            .result(callID: "c1", output: "captured"),
        ])
        #expect(exchange.inputFingerprints.count == 4)
        #expect(exchange.status == "completed")
        #expect(exchange.outputs == [
            .reasoning,
            .call(.init(id: "c2", name: "speak", arguments: #"{"lines":["Hi"],"detail":"More."}"#)),
            .text("prose"),
        ])
        #expect(exchange.usage?.input == 10)
        #expect(exchange.usage?.cacheRead == 4)
        #expect(exchange.usage?.cacheWrite == nil)
        #expect(exchange.usage?.output == 7)
    }

    @Test func legacyRecordsUseTheResponsesReader() {
        let exchange = RecordedExchange.read(
            request: ["input": [["type": "text", "text": "hello"], ["type": "image"]]],
            response: nil)
        #expect(exchange.input == [.text("hello"), .image(nil)])
        #expect(RecordedExchange.read(request: nil, response: nil) == RecordedExchange())
    }

    /// Claude sessions recorded on the Responses route keep reading as they were sent.
    @Test func anOldResponsesShapedClaudeRecordStillReadsAsResponses() {
        let request = json(#"""
        {"model":"claude-opus-5","instructions":"You are Jarvis.","reasoning":{"effort":"low"},
         "input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]},
                  {"type":"function_call","call_id":"c1","name":"speak","arguments":"{\"lines\":[\"Hi\"]}"},
                  {"type":"function_call_output","call_id":"c1","output":"shown"}]}
        """#)
        let response = json(#"{"status":"completed","output":[{"type":"function_call","call_id":"c2","name":"speak","arguments":"{}"}]}"#)
        let exchange = RecordedExchange.read(request: request, response: response)
        #expect(exchange == ResponsesWireFormat.readRecorded(request: request, response: response))
        #expect(exchange.instructions == "You are Jarvis.")
        #expect(exchange.input[1] == .call(.init(id: "c1", name: "speak", arguments: #"{"lines":["Hi"]}"#)))
        #expect(exchange.outputs == [.call(.init(id: "c2", name: "speak", arguments: "{}"))])
    }

    @Test func messagesShapedRecordsUseTheMessagesReader() {
        let request = json(#"""
        {"model":"claude-opus-5","system":"You are Jarvis.","max_tokens":2048,
         "messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
        """#)
        let response = json(#"{"id":"msg_1","type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}"#)
        let exchange = RecordedExchange.read(request: request, response: response)
        #expect(exchange == MessagesWireFormat.readRecorded(request: request, response: response))
        #expect(exchange.instructions == "You are Jarvis.")
        #expect(exchange.outputs == [.text("ok")])
        // A failed call records the request alone, and a refused one an Anthropic error body.
        #expect(RecordedExchange.read(request: request, response: nil).instructions == "You are Jarvis.")
        let refused = RecordedExchange.read(
            request: request, response: json(#"{"type":"error","error":{"type":"rate_limit_error","message":"m"}}"#))
        #expect(refused.instructions == "You are Jarvis.")
        #expect(refused.outputs.isEmpty)
        #expect(RecordedExchange.read(request: nil, response: response).outputs == [.text("ok")])
    }

    @Test func interactionsShapedRecordsUseTheInteractionsReader() {
        let request: [String: Any] = ["model": "gemini-3.8-flash", "system_instruction": "You are Jarvis.",
                                      "generation_config": ["thinking_level": "low"]]
        let exchange = RecordedExchange.read(request: request, response: nil)
        #expect(exchange == InteractionsWireFormat.readRecorded(request: request, response: nil))
        #expect(exchange.instructions == "You are Jarvis.")
        let response: [String: Any] = ["status": "completed", "steps": [["type": "model_output", "content": [["type": "text", "text": "ok"]]]]]
        #expect(RecordedExchange.read(request: nil, response: response).outputs == [.text("ok")])
    }
}
