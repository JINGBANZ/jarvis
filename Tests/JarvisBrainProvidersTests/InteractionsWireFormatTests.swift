import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct InteractionsWireFormatTests {
    let wire = InteractionsWireFormat(model: "gemini-3.8-flash", reasoningEffort: "low", maxOutputTokens: 2_048)

    func body(_ messages: [ChatMessage], tools: [ToolDef] = coachTools(detailEnabled: true),
              choice: ToolChoice = .required, wire: InteractionsWireFormat? = nil) throws -> [String: Any] {
        let data = try (wire ?? self.wire).encode(messages: messages, tools: tools, toolChoice: choice)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func input(_ body: [String: Any]) -> [[String: Any]] { body["input"] as? [[String: Any]] ?? [] }
    func types(_ body: [String: Any]) -> [String] { input(body).map { $0["type"] as? String ?? "?" } }
    func config(_ body: [String: Any]) -> [String: Any] { body["generation_config"] as? [String: Any] ?? [:] }

    @Test func encodesTheStatelessRequestShape() throws {
        let b = try body([.system("You are Jarvis."), .system("Be brief."), .user("hi"), .userImage("AAAA")])
        #expect(b["model"] as? String == "gemini-3.8-flash")
        #expect(b["store"] as? Bool == false)
        #expect(b["system_instruction"] as? String == "You are Jarvis.\n\nBe brief.")
        #expect(b["tool_choice"] == nil)
        #expect(b["parallel_tool_calls"] == nil)
        #expect(config(b)["thinking_level"] as? String == "low")
        #expect(config(b)["thinking_summaries"] as? String == "none")
        #expect(config(b)["max_output_tokens"] as? Int == 2_048)
        #expect(config(b)["tool_choice"] as? String == "any")
        #expect(types(b) == ["user_input", "user_input"])
        let image = (input(b)[1]["content"] as? [[String: Any]])?.first
        #expect(image?["type"] as? String == "image")
        #expect(image?["mime_type"] as? String == "image/jpeg")
        #expect(image?["data"] as? String == "AAAA")
        let declared = try #require(b["tools"] as? [[String: Any]])
        #expect(declared.compactMap { $0["name"] as? String } == coachTools(detailEnabled: true).map(\.name))
        #expect(declared.allSatisfy { $0["type"] as? String == "function" && $0["strict"] == nil })
    }

    @Test func narrowingAndForcingUseAllowedTools() throws {
        let narrowed = config(try body([.user("hi")], choice: .allowed(["speak", "load_skill"])))
        let set = (narrowed["tool_choice"] as? [String: Any])?["allowed_tools"] as? [String: Any]
        #expect(set?["mode"] as? String == "any")
        #expect(set?["tools"] as? [String] == ["speak", "load_skill"])
        let forced = config(try body([.user("hi")], choice: .force("speak")))
        let one = (forced["tool_choice"] as? [String: Any])?["allowed_tools"] as? [String: Any]
        #expect(one?["tools"] as? [String] == ["speak"])
        #expect(config(try body([.user("hi")], choice: .auto))["tool_choice"] as? String == "auto")
    }

    @Test func aToolLessRequestOmitsToolsAndChoice() throws {
        let b = try body([.user("summarize")], tools: [], choice: .auto)
        #expect(b["tools"] == nil)
        #expect(config(b)["tool_choice"] == nil)
    }

    @Test func noneEffortIsMinimal() throws {
        let b = try body([.user("hi")], wire: InteractionsWireFormat(
            model: "gemini-3.5-flash", reasoningEffort: "none", maxOutputTokens: 1_024))
        #expect(config(b)["thinking_level"] as? String == "minimal")
    }

    @Test func rawStepsReplayVerbatimAndResultsNameTheirCall() throws {
        let id = "call_326665_ab12cd34"
        let b = try body([
            .user("look"),
            .rawItems([#"{"type":"thought","signature":"EmcKZQER"}"#,
                       #"{"type":"function_call","id":"call_326665_ab12cd34","name":"capture_screen","arguments":{}}"#],
                      calls: [RawToolCall(id: id, name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "Screenshot captured.", toolCallId: id),
            .userImage("AAAA"),
        ])
        #expect(types(b) == ["user_input", "thought", "function_call", "function_result", "user_input"])
        #expect(input(b)[1]["signature"] as? String == "EmcKZQER")
        #expect(input(b)[3]["call_id"] as? String == id)
        #expect(input(b)[3]["name"] as? String == "capture_screen")
        #expect(input(b)[3]["result"] as? String == "Screenshot captured.")
    }

    @Test func neutralCallsGetThePlaceholderThought() throws {
        let b = try body([
            .user("look"),
            .assistantToolCalls([
                RawToolCall(id: "call_1", name: "capture_screen", argumentsJSON: "{}"),
                RawToolCall(id: "call_2", name: "stay_silent", argumentsJSON: "{}"),
            ]),
            .init(role: .tool, text: "captured", toolCallId: "call_1"),
            .init(role: .tool, text: "not executed", toolCallId: "call_2"),
            .user("next"),
        ])
        #expect(types(b) == ["user_input", "thought", "function_call", "function_call",
                             "function_result", "function_result", "user_input"])
        #expect(input(b)[1]["signature"] as? String == "skip_thought_signature_validator")
        #expect(input(b)[5]["name"] as? String == "stay_silent")
    }

    @Test func inputNeverOpensWithACall() throws {
        let b = try body([
            .system("You are Jarvis."),
            .assistantToolCalls([RawToolCall(
                id: "runner_1a2b3c4d", name: "load_skill", argumentsJSON: #"{"name":"coding"}"#)]),
            .init(role: .tool, text: "Loaded coding.", toolCallId: "runner_1a2b3c4d"),
            .user("The user pressed Show code."),
        ])
        #expect(types(b) == ["user_input", "thought", "function_call", "function_result", "user_input"])
        let opening = (input(b)[0]["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(opening == InteractionsWireFormat.sessionStart)
        #expect((input(b)[2]["arguments"] as? [String: Any])?["name"] as? String == "coding")
    }

    @Test func assistantTextIsModelOutput() throws {
        let b = try body([.user("hi"), ChatMessage(role: .assistant, text: "prose"), .user("call speak")])
        #expect(types(b) == ["user_input", "model_output", "user_input"])
    }

    @Test func decodesACallReplyAndMakesItsIdUnique() throws {
        let data = Data(#"{"status":"requires_action","object":"interaction","model":"gemini-3.8-flash","steps":[{"signature":"EmcKZQER","type":"thought"},{"id":"call_326665","type":"function_call","name":"speak","arguments":{"lines":["Try a hash map."],"detail":null}}],"usage":{"total_input_tokens":2020,"total_cached_tokens":0,"total_output_tokens":16,"total_thought_tokens":44}}"#.utf8)
        let first = try wire.decode(data)
        let second = try wire.decode(data)
        let id = try #require(first.rawToolCalls.first?.id)
        #expect(id.hasPrefix("call_326665_"))
        #expect(id != second.rawToolCalls.first?.id)
        #expect(first.toolCalls == [.speak(callId: id, lines: ["Try a hash map."])])
        #expect(first.incompleteReason == nil)
        #expect(first.outputText == nil)
        #expect(first.outputItemsJSON.count == 2)
        #expect(first.outputItemsJSON[0].contains(#""signature":"EmcKZQER""#))
        #expect(first.outputItemsJSON[1].contains(#""id":"\#(id)""#))
    }

    @Test func decodesATextReply() throws {
        let response = try wire.decode(Data(#"{"status":"completed","steps":[{"signature":"El4KXAER","type":"thought"},{"content":[{"text":"The user outlined a hash map.","type":"text"}],"type":"model_output"}]}"#.utf8))
        #expect(response.outputText == "The user outlined a hash map.")
        #expect(response.toolCalls.isEmpty)
        #expect(response.incompleteReason == nil)
    }

    @Test func anUnfinishedStatusIsTruncation() throws {
        let cut = try wire.decode(Data(#"{"status":"incomplete","object":"interaction","model":"gemini-3.8-flash"}"#.utf8))
        #expect(cut.incompleteReason == "incomplete")
        #expect(cut.toolCalls.isEmpty && cut.outputItemsJSON.isEmpty)
        for status in ["cancelled", "in_progress", "budget_exceeded"] {
            #expect(try wire.decode(Data(#"{"status":"\#(status)","steps":[]}"#.utf8)).incompleteReason == status)
        }
    }

    /// Activity must be able to say why Gemini gave up.
    @Test func aFailedReplyQuotesItsErrors() throws {
        let failed = try wire.decode(Data(#"{"status":"failed","errors":[{"code":"malformed_function_call","message":"The model produced an invalid call."}]}"#.utf8))
        #expect(failed.incompleteReason == "failed (malformed_function_call: The model produced an invalid call.)")
        #expect(try wire.decode(Data(#"{"status":"failed"}"#.utf8)).incompleteReason == "failed")
    }

    @Test func echoedInputStepsAreNotReplayed() throws {
        let response = try wire.decode(Data(#"{"status":"completed","steps":[{"type":"user_input","content":[{"type":"text","text":"hi"}]},{"type":"model_output","content":[{"type":"text","text":"ok"}]}]}"#.utf8))
        #expect(response.outputItemsJSON.count == 1)
        #expect(response.outputText == "ok")
    }

    @Test func aRecordedExchangeReadsIntoTheSharedView() {
        func json(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        let request = json(#"""
        {"model":"gemini-3.8-flash","store":false,"system_instruction":"You are Jarvis.",
         "generation_config":{"thinking_level":"low","thinking_summaries":"none","max_output_tokens":2048,
           "tool_choice":{"allowed_tools":{"mode":"any","tools":["speak"]}}},
         "tools":[{"type":"function","name":"speak","parameters":{"type":"object","properties":{"lines":{},"detail":{}}}}],
         "input":[{"type":"user_input","content":[{"type":"text","text":"Session start."}]},
                  {"type":"thought","signature":"skip_thought_signature_validator"},
                  {"type":"function_call","id":"runner_1a2b3c4d","name":"load_skill","arguments":{"name":"coding"}},
                  {"type":"function_result","call_id":"runner_1a2b3c4d","name":"load_skill","result":"Loaded coding."},
                  {"type":"user_input","content":[{"type":"image","mime_type":"image/jpeg","data":"[base64 image omitted]"}]}]}
        """#)
        let response = json(#"""
        {"status":"requires_action","steps":[{"type":"thought","signature":"EmcKZQER"},
          {"type":"function_call","id":"call_1_ab12cd34","name":"speak","arguments":{"lines":["Hi"],"detail":"More."}}],
         "usage":{"total_input_tokens":2020,"total_cached_tokens":0,"total_output_tokens":16,"total_thought_tokens":44}}
        """#)
        let exchange = InteractionsWireFormat.readRecorded(request: request, response: response)
        #expect(exchange.model == "gemini-3.8-flash")
        #expect(exchange.parameters.map(\.name) == ["thinking_level", "max_output_tokens", "tool_choice"])
        #expect(exchange.instructions == "You are Jarvis.")
        #expect(exchange.toolNames == ["speak"])
        #expect(exchange.speakParameters == ["detail", "lines"])
        #expect(exchange.toolChoiceType == "allowed_tools")
        #expect(exchange.input.count == 5)
        #expect(exchange.input[0] == .message(role: "user", parts: ["Session start."]))
        if case .reasoning = exchange.input[1] {} else { Issue.record("a thought step reads as reasoning") }
        #expect(exchange.input[2] == .call(.init(
            id: "runner_1a2b3c4d", name: "load_skill", arguments: #"{"name":"coding"}"#)))
        #expect(exchange.input[3] == .result(callID: "runner_1a2b3c4d", output: "Loaded coding."))
        #expect(exchange.input[4] == .message(role: "user", parts: ["[base64 image omitted]"]))
        #expect(exchange.status == "requires_action")
        #expect(exchange.outputs == [.reasoning, .call(.init(
            id: "call_1_ab12cd34", name: "speak", arguments: #"{"detail":"More.","lines":["Hi"]}"#))])
        #expect(exchange.usage?.input == 2020)
        #expect(exchange.usage?.cacheRead == 0)
        #expect(exchange.usage?.output == 60)
    }
}
