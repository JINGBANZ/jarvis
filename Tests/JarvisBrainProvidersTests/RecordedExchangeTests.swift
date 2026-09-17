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
        let exchange = RecordedExchange.read(provider: "openai", request: request, response: response)
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
            provider: "claude-code",
            request: ["input": [["type": "text", "text": "hello"], ["type": "image"]]],
            response: nil)
        #expect(exchange.input == [.text("hello"), .image(nil)])
        #expect(RecordedExchange.read(provider: nil, request: nil, response: nil) == RecordedExchange())
    }

    @Test func geminiRecordsUseTheInteractionsReader() {
        let request: [String: Any] = ["model": "gemini-3.8-flash", "system_instruction": "You are Jarvis."]
        let exchange = RecordedExchange.read(provider: "gemini", request: request, response: nil)
        #expect(exchange == InteractionsWireFormat.readRecorded(request: request, response: nil))
        #expect(exchange.instructions == "You are Jarvis.")
    }
}
