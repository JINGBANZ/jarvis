import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct MessagesWireFormatTests {
    let wire = MessagesWireFormat(model: "claude-opus-5", reasoningEffort: "low", maxOutputTokens: 2_048, stream: false)

    func body(_ messages: [ChatMessage], tools: [ToolDef] = coachTools,
              choice: ToolChoice = .auto) throws -> [String: Any] {
        let data = try wire.encode(messages: messages, tools: tools, toolChoice: choice)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func turns(_ body: [String: Any]) -> [[String: Any]] { body["messages"] as? [[String: Any]] ?? [] }
    func roles(_ body: [String: Any]) -> [String] { turns(body).map { $0["role"] as? String ?? "?" } }
    func blocks(_ turn: [String: Any]) -> [[String: Any]] { turn["content"] as? [[String: Any]] ?? [] }
    func types(_ turn: [String: Any]) -> [String] { blocks(turn).map { $0["type"] as? String ?? "?" } }

    @Test func encodesTheRequestShape() throws {
        let b = try body([.system("You are Jarvis."), .system("Be brief."), .user("hi"), .userImage("AAAA")])
        #expect(b["model"] as? String == "claude-opus-5")
        #expect(b["max_tokens"] as? Int == 2_048)
        #expect(b["system"] as? String == "You are Jarvis.\n\nBe brief.")
        #expect(b["stream"] == nil)
        #expect(b["store"] == nil)
        #expect((b["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((b["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let choice = try #require(b["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "auto")
        #expect(choice["disable_parallel_tool_use"] as? Bool == true)
        // Consecutive user blocks share one turn.
        #expect(roles(b) == ["user"])
        #expect(types(turns(b)[0]) == ["text", "image"])
        let image = blocks(turns(b)[0])[1]["source"] as? [String: Any]
        #expect(image?["type"] as? String == "base64")
        #expect(image?["media_type"] as? String == "image/jpeg")
        #expect(image?["data"] as? String == "AAAA")
        let declared = try #require(b["tools"] as? [[String: Any]])
        #expect(declared.map { $0["name"] as? String } == coachTools.map(\.name))
        #expect(declared.allSatisfy { $0["input_schema"] is [String: Any] && $0["description"] is String })
        #expect(declared.allSatisfy { $0["strict"] == nil && $0["eager_input_streaming"] == nil && $0["type"] == nil })
    }

    @Test func wireHeadersNameTheAPIVersion() {
        #expect(wire.requestHeaders == ["anthropic-version": "2023-06-01"])
    }

    @Test(arguments: [ToolChoice.auto, .required, .allowed(["speak", "load_skill"]), .force("speak")])
    func everyToolChoiceIsSentAsAuto(choice: ToolChoice) throws {
        let toolChoice = try #require(try body([.user("hi")], choice: choice)["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "auto")
        #expect(toolChoice["disable_parallel_tool_use"] as? Bool == true)
        #expect(toolChoice["name"] == nil)
    }

    /// The history summarizer runs on Haiku 4.5, which rejects adaptive thinking and `effort`.
    @Test func aToolLessRequestOmitsToolsChoiceThinkingAndEffort() throws {
        let b = try body([.user("summarize")], tools: [])
        #expect(b["tools"] == nil)
        #expect(b["tool_choice"] == nil)
        #expect(b["thinking"] == nil)
        #expect(b["output_config"] == nil)
        #expect(b["max_tokens"] as? Int == 2_048)
        #expect(roles(b) == ["user"])
    }

    /// Models write arguments in schema order, so `lines` must reach the wire before `detail`.
    @Test func toolSchemasKeepTheirAuthoredKeyOrder() throws {
        let tools = coachTools
        let data = try wire.encode(messages: [.user("hi")], tools: tools, toolChoice: .auto)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(speakTool.parametersJSON))
        let lines = try #require(text.range(of: #""lines""#))
        let detail = try #require(text.range(of: #""detail""#))
        #expect(lines.lowerBound < detail.lowerBound)
        let declared = try #require(body([.user("hi")])["tools"] as? [[String: Any]])
        let speak = declared[1]["input_schema"] as? [String: Any]
        #expect(speak?["required"] as? [String] == ["lines", "detail"])
    }

    @Test func rawBlocksReplayVerbatimAndARoundsResultsShareOneUserTurn() throws {
        let b = try body([
            .user("look"),
            .rawItems([#"{"type":"thinking","thinking":"","signature":"EmcKZQER"}"#,
                       #"{"type":"tool_use","id":"toolu_01","name":"capture_screen","input":{}}"#,
                       #"{"type":"tool_use","id":"toolu_02","name":"stay_silent","input":{}}"#],
                      calls: [RawToolCall(id: "toolu_01", name: "capture_screen", argumentsJSON: "{}"),
                              RawToolCall(id: "toolu_02", name: "stay_silent", argumentsJSON: "{}")]),
            .init(role: .tool, text: "Screenshot captured.", toolCallId: "toolu_01"),
            .init(role: .tool, text: "not executed", toolCallId: "toolu_02"),
            .userImage("AAAA"),
        ])
        #expect(roles(b) == ["user", "assistant", "user"])
        #expect(types(turns(b)[1]) == ["thinking", "tool_use", "tool_use"])
        #expect(blocks(turns(b)[1])[0]["signature"] as? String == "EmcKZQER")
        #expect(types(turns(b)[2]) == ["tool_result", "tool_result", "image"])
        let result = blocks(turns(b)[2])[0]
        #expect(result["tool_use_id"] as? String == "toolu_01")
        #expect(result["content"] as? String == "Screenshot captured.")
        #expect(blocks(turns(b)[2])[1]["tool_use_id"] as? String == "toolu_02")
    }

    @Test func neutralCallsAreRebuiltAsToolUse() throws {
        let b = try body([
            .user("look"),
            .assistantToolCalls([RawToolCall(id: "call_1", name: "load_skill", argumentsJSON: #"{"name":"coding"}"#)]),
            .init(role: .tool, text: "Loaded coding.", toolCallId: "call_1"),
            .user("next"),
        ])
        #expect(roles(b) == ["user", "assistant", "user"])
        let call = blocks(turns(b)[1])[0]
        #expect(call["type"] as? String == "tool_use")
        #expect(call["id"] as? String == "call_1")
        #expect((call["input"] as? [String: Any])?["name"] as? String == "coding")
        #expect(types(turns(b)[2]) == ["tool_result", "text"])
    }

    @Test func aConversationNeverOpensWithAnAssistantTurn() throws {
        let b = try body([
            .system("You are Jarvis."),
            .assistantToolCalls([RawToolCall(id: "runner_1a2b3c4d", name: "load_skill", argumentsJSON: #"{"name":"coding"}"#)]),
            .init(role: .tool, text: "Loaded coding.", toolCallId: "runner_1a2b3c4d"),
            .user("The user pressed Show code."),
        ])
        #expect(roles(b) == ["user", "assistant", "user"])
        #expect(blocks(turns(b)[0]).first?["text"] as? String == MessagesWireFormat.sessionStart)
    }

    @Test func assistantTextIsATextBlock() throws {
        let b = try body([.user("hi"), ChatMessage(role: .assistant, text: "prose"), .user("call speak")])
        #expect(roles(b) == ["user", "assistant", "user"])
        #expect(blocks(turns(b)[1]) .first?["text"] as? String == "prose")
    }

    @Test func decodesAToolUseReply() throws {
        let data = Data(#"{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"thinking","thinking":"","signature":"EmcKZQER"},{"type":"tool_use","id":"toolu_01","name":"speak","input":{"lines":["Try a hash map."],"detail":null}}],"stop_reason":"tool_use","stop_details":null,"usage":{"input_tokens":20,"cache_read_input_tokens":3360,"cache_creation_input_tokens":0,"output_tokens":60}}"#.utf8)
        let response = try wire.decode(data)
        #expect(response.toolCalls == [.speak(callId: "toolu_01", lines: ["Try a hash map."])])
        #expect(response.rawToolCalls == [RawToolCall(
            id: "toolu_01", name: "speak", argumentsJSON: #"{"detail":null,"lines":["Try a hash map."]}"#)])
        #expect(response.incompleteReason == nil)
        #expect(response.outputText == nil)
        #expect(response.outputItemsJSON.count == 2)
        #expect(response.outputItemsJSON[0].contains(#""signature":"EmcKZQER""#))
        #expect(response.outputItemsJSON[1].contains(#""id":"toolu_01""#))
    }

    @Test func aCallToolBlockDecodesIntoTheRoutedInvocation() throws {
        let reply = #"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"call_tool","input":{"name":"search_prep_notes","arguments":"{\"query\":\"rate limiter\"}"}}]}"#
        let response = try wire.decode(Data(reply.utf8))
        #expect(response.toolCalls == [.searchPrepNotes(callId: "t1", query: "rate limiter")])
        #expect(response.rawToolCalls.map(\.name) == ["call_tool"])
    }

    @Test func malformedSpeakArgumentsRemainAvailableForSchemaRecovery() throws {
        let data = Data(#"""
        {"id":"msg_malformed","type":"message","role":"assistant","model":"claude-opus-5",
         "content":[{"type":"tool_use","id":"toolu_malformed","name":"speak",
                     "input":{"lines":"\n<parameter name=\"detail\">Explain the queue invariant.\n"}}],
         "stop_reason":"tool_use","usage":{"input_tokens":20,"output_tokens":60}}
        """#.utf8)
        let response = try wire.decode(data)

        #expect(response.toolCalls.isEmpty)
        #expect(response.outputText == nil)
        #expect(response.incompleteReason == nil)
        let raw = try #require(response.rawToolCalls.first)
        #expect(raw.id == "toolu_malformed")
        #expect(raw.name == "speak")
        let arguments = try #require(
            JSONSerialization.jsonObject(with: Data(raw.argumentsJSON.utf8)) as? [String: Any])
        #expect(arguments["lines"] as? String == "\n<parameter name=\"detail\">Explain the queue invariant.\n")
        #expect(arguments["detail"] == nil)

        let continuation = try body([
            .user("Explain the queue."),
            .rawItems(response.outputItemsJSON, calls: response.rawToolCalls),
            .init(role: .tool, text: "Arguments did not match the schema.", toolCallId: raw.id),
        ])
        let replayed = blocks(turns(continuation)[1])[0]
        #expect(replayed["id"] as? String == "toolu_malformed")
        #expect((replayed["input"] as? NSDictionary) == (arguments as NSDictionary))
        #expect(blocks(turns(continuation)[2])[0]["tool_use_id"] as? String == "toolu_malformed")
    }

    @Test func decodesATextReply() throws {
        let response = try wire.decode(Data(#"{"type":"message","content":[{"type":"text","text":"The user "},{"type":"text","text":"outlined a hash map."}],"stop_reason":"end_turn"}"#.utf8))
        #expect(response.outputText == "The user outlined a hash map.")
        #expect(response.toolCalls.isEmpty)
        #expect(response.incompleteReason == nil)
    }

    @Test func anUnfinishedStopReasonIsTruncation() throws {
        let cut = try wire.decode(Data(#"{"type":"message","content":[{"type":"tool_use","id":"toolu_01","name":"speak","input":{"lines":["Try"]}}],"stop_reason":"max_tokens"}"#.utf8))
        #expect(cut.incompleteReason == "max_tokens")
        #expect(cut.toolCalls.count == 1)
        let overflow = try wire.decode(Data(#"{"type":"message","content":[],"stop_reason":"model_context_window_exceeded"}"#.utf8))
        #expect(overflow.incompleteReason == "model_context_window_exceeded")
        #expect(try wire.decode(Data(#"{"type":"message","content":[]}"#.utf8)).incompleteReason == "unknown stop reason")
    }

    @Test func aRefusalThrowsWithItsStopDetails() throws {
        let data = Data(#"{"type":"message","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"declined"}}"#.utf8)
        do {
            _ = try wire.decode(data)
            Issue.record("a refusal must throw")
        } catch let refusal as RefusedReply {
            #expect(refusal.category == "cyber")
            #expect(refusal.explanation == "declined")
        }
    }

    @Test func aRecordedExchangeReadsIntoTheSharedView() throws {
        func json(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        let request = json(#"""
        {"model":"claude-opus-5","max_tokens":2048,"system":"You are Jarvis.",
         "thinking":{"type":"adaptive"},"output_config":{"effort":"low"},
         "tool_choice":{"type":"auto","disable_parallel_tool_use":true},
         "tools":[{"name":"speak","description":"d","input_schema":{"type":"object","properties":{"lines":{},"detail":{}}}}],
         "messages":[{"role":"user","content":[{"type":"text","text":"Session start."}]},
                     {"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"EmcKZQER"},
                                                    {"type":"tool_use","id":"runner_1a2b3c4d","name":"load_skill","input":{"name":"coding"}}]},
                     {"role":"user","content":[{"type":"tool_result","tool_use_id":"runner_1a2b3c4d","content":"Loaded coding."},
                                               {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"[base64 image omitted]"}}]}]}
        """#)
        let response = json(#"""
        {"id":"msg_01","type":"message","role":"assistant","stop_reason":"tool_use","stop_details":null,
         "content":[{"type":"thinking","thinking":"","signature":"EmcKZQER"},
                    {"type":"tool_use","id":"toolu_01","name":"speak","input":{"lines":["Hi"],"detail":"More."}}],
         "usage":{"input_tokens":20,"cache_read_input_tokens":3360,"cache_creation_input_tokens":12,"output_tokens":60}}
        """#)
        let exchange = MessagesWireFormat.readRecorded(request: request, response: response)
        #expect(exchange.model == "claude-opus-5")
        #expect(exchange.parameters.map(\.name) == ["output_config", "max_tokens", "tool_choice"])
        #expect(exchange.parameters[1].value == "2048")
        #expect(exchange.instructions == "You are Jarvis.")
        #expect(exchange.toolNames == ["speak"])
        #expect(exchange.speakParameters == ["detail", "lines"])
        #expect(exchange.toolChoiceType == "auto")
        #expect(exchange.input.count == 5)
        #expect(exchange.inputFingerprints.count == exchange.input.count)
        #expect(exchange.input[0] == .message(role: "user", parts: ["Session start."]))
        if case .reasoning = exchange.input[1] {} else { Issue.record("a thinking block reads as reasoning") }
        #expect(exchange.input[2] == .call(.init(
            id: "runner_1a2b3c4d", name: "load_skill", arguments: #"{"name":"coding"}"#)))
        #expect(exchange.input[3] == .result(callID: "runner_1a2b3c4d", output: "Loaded coding."))
        #expect(exchange.input[4] == .message(role: "user", parts: ["[base64 image omitted]"]))
        #expect(exchange.status == "tool_use")
        #expect(exchange.incompleteDetail == nil)
        let refused = MessagesWireFormat.readRecorded(request: nil, response: json(
            #"{"type":"message","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#))
        #expect(refused.status == "refusal")
        #expect(refused.incompleteDetail == #"{"category":"cyber","type":"refusal"}"#)
        #expect(exchange.outputs == [.reasoning, .call(.init(
            id: "toolu_01", name: "speak", arguments: #"{"detail":"More.","lines":["Hi"]}"#))])
        #expect(exchange.usage?.input == 20)
        #expect(exchange.usage?.cacheRead == 3360)
        #expect(exchange.usage?.cacheWrite == 12)
        #expect(exchange.usage?.output == 60)
    }
}
