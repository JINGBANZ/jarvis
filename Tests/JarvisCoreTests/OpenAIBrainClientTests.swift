import Foundation
import Testing
@testable import JarvisCore

private func http(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                    statusCode: code, httpVersion: nil, headerFields: headers)!
}

@Suite struct OpenAIBrainClientTests {
    @Test func decodesSpeakToolCall() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\\"text\\":\\"Try a hash map.\\"}"}
        ]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.speak(callId: "call_1", text: "Try a hash map.")])
    }

    @Test func decodesCaptureScreenToolCall() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":"{}"}
        ]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.captureScreen(callId: "call_9")])
        #expect(resp.rawToolCalls == [RawToolCall(id: "call_9", name: "capture_screen", argumentsJSON: "{}")])
    }

    @Test func noToolCallsMeansSilent() async throws {
        let json = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"(thinking)"}]}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls.isEmpty)
    }

    /// A token-truncated response (status=incomplete, max_output_tokens) must surface its reason
    /// so an empty tool-call list isn't mistaken for deliberate silence.
    @Test func decodeFlagsIncompleteResponse() async throws {
        let json = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls.isEmpty)
        #expect(resp.incompleteReason == "max_output_tokens")
    }

    /// A normal completed response carries no incomplete reason.
    @Test func decodeCompletedResponseHasNoIncompleteReason() async throws {
        let json = #"{"status":"completed","output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"text\":\"hi\"}"}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.incompleteReason == nil)
    }

    /// When a conversation id is supplied, it's sent as the Responses `conversation` field, and
    /// state is stored server-side (store:true).
    @Test func encodesConversationAndStore() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                     toolChoice: .auto, conversationId: "conv_abc")
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"conversation\":\"conv_abc\""))
        #expect(body.contains("\"store\":true"))
    }

    /// createConversation POSTs to the conversations endpoint and returns the new id.
    @Test func createConversationParsesId() async throws {
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(#"{"id":"conv_new123"}"#.utf8), http(200)) })
        let id = try await client.createConversation()
        #expect(id == "conv_new123")
    }

    @Test func httpErrorThrows() async {
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5", maxRetries: 0,
                                       send: { _ in (Data("nope".utf8), http(400)) })
        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
    }

    /// 429 is retried with backoff; a subsequent 200 succeeds.
    @Test func retriesOn429ThenSucceeds() async throws {
        let attempts = Counter()
        let ok = #"{"output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"text\":\"hi\"}"}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       maxRetries: 3, backoffBaseSeconds: 0,
                                       send: { _ in
            let n = attempts.next()
            return n < 2 ? (Data("rate".utf8), http(429)) : (Data(ok.utf8), http(200))
        })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.speak(callId: "c", text: "hi")])
        #expect(attempts.value == 3) // two 429s + one 200
    }

    /// Request body uses the Responses shape + hardening flags.
    @Test func encodesResponsesRequestShape() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5", reasoningEffort: "low",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        let convo: [ChatMessage] = [
            .system("be a coach"),
            .user("transcript"),
            .assistantToolCalls([RawToolCall(id: "call_1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "screenshot captured", toolCallId: "call_1"),
            .userImage("ZmFrZQ=="),
        ]
        _ = try await client.respond(messages: convo, tools: coachTools)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"instructions\""))
        #expect(body.contains("\"function_call\""))
        #expect(body.contains("\"function_call_output\""))
        #expect(body.contains("\"call_id\":\"call_1\""))
        #expect(body.contains("\"input_image\""))
        #expect(body.contains("\"reasoning\""))
        #expect(body.contains("\"store\":true"))   // server-side conversation continuity
        #expect(body.contains("\"max_output_tokens\""))
        #expect(body.contains("\"parallel_tool_calls\":false"))
        #expect(body.contains("\"name\":\"capture_screen\""))
    }

    /// Default tool choice is "auto".
    @Test func defaultToolChoiceIsAuto() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_choice\":\"auto\""))
    }

    /// Forcing a specific function encodes the Responses tool_choice object shape.
    @Test func forceToolChoiceEncodesFunctionObject() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools, toolChoice: .force("speak"))
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_choice\""))
        #expect(body.contains("\"type\":\"function\""))
        #expect(body.contains("\"name\":\"speak\""))
    }
}

/// Thread-safe capture box for inspecting the request body from a @Sendable send closure.
final class CapturedBody: @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()
    func set(_ d: Data?) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}

/// Thread-safe call counter for retry tests.
final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
