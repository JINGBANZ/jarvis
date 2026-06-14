import Foundation
import Testing
@testable import JarvisCore

@Suite struct OpenAIBrainClientTests {
    @Test func decodesSpeakToolCall() async throws {
        let json = """
        {"choices":[{"message":{"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"speak","arguments":"{\\"text\\":\\"Try a hash map.\\"}"}}
        ]}}]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.speak(callId: "call_1", text: "Try a hash map.")])
    }

    @Test func decodesCaptureScreenToolCall() async throws {
        let json = """
        {"choices":[{"message":{"tool_calls":[
          {"id":"c9","type":"function","function":{"name":"capture_screen","arguments":"{}"}}
        ]}}]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.captureScreen(callId: "c9")])
        #expect(resp.rawToolCalls == [RawToolCall(id: "c9", name: "capture_screen", argumentsJSON: "{}")])
    }

    @Test func noToolCallsMeansSilent() async throws {
        let json = #"{"choices":[{"message":{"content":"(thinking)"}}]}"#
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

    /// B3: an assistant tool-call message encodes as role:assistant with tool_calls.
    @Test func encodesAssistantToolCallsTurn() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"choices":[{"message":{}}]}"#.utf8), 200) })
        let convo: [ChatMessage] = [
            .assistantToolCalls([RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(role: .tool, text: "screenshot captured", toolCallId: "c1"),
        ]
        _ = try await client.respond(messages: convo, tools: coachTools)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_calls\""))
        #expect(body.contains("\"tool_call_id\":\"c1\""))
    }
}

/// Thread-safe capture box for inspecting the request body from a @Sendable send closure.
final class CapturedBody: @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()
    func set(_ d: Data?) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}
