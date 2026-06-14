import Foundation
import Testing
@testable import JarvisCore

@Suite struct OpenAIBrainClientTests {
    @Test func decodesSpeakToolCall() async throws {
        // Responses API: function calls arrive in the `output` array.
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\\"text\\":\\"Try a hash map.\\"}"}
        ]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
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
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.captureScreen(callId: "call_9")])
        #expect(resp.rawToolCalls == [RawToolCall(id: "call_9", name: "capture_screen", argumentsJSON: "{}")])
    }

    @Test func noToolCallsMeansSilent() async throws {
        // A plain text message in output, no function_call → stay silent.
        let json = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"(thinking)"}]}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls.isEmpty)
    }

    @Test func httpErrorThrows() async {
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data("nope".utf8), 500) })
        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
    }

    /// Request body uses the Responses shape: instructions, flat tools, reasoning, and the
    /// assistant function_call / function_call_output threading (B3).
    @Test func encodesResponsesRequestShape() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5", reasoningEffort: "low",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), 200) })
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
        // Flat function tool shape (no nested "function" wrapper key).
        #expect(body.contains("\"name\":\"capture_screen\""))
    }
}

/// Thread-safe capture box for inspecting the request body from a @Sendable send closure.
final class CapturedBody: @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()
    func set(_ d: Data?) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}
