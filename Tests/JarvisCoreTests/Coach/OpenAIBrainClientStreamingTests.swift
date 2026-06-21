import Foundation
import Testing
@testable import JarvisCore

private func http(_ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                    statusCode: code, httpVersion: nil, headerFields: nil)!
}

/// Build an SSE line stream from scripted `data:` payloads (the wire `event:` lines are optional —
/// the client switches on the JSON `type`, so we only need the data lines plus blank separators).
private func sseStream(_ dataLines: [String]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for d in dataLines { continuation.yield("data: \(d)"); continuation.yield("") }
        continuation.finish()
    }
}

/// Collects streamed lines from a @Sendable callback.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock(); private var _lines: [String] = []
    func add(_ l: String) { lock.lock(); _lines.append(l); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

@Suite struct OpenAIBrainClientStreamingTests {
    /// A speak call streamed as argument deltas: each completed line is delivered to onLine in order,
    /// and the final BrainResponse matches what the terminal response.completed event carries.
    @Test func streamsSpeakLinesAndReturnsFinalResponse() async throws {
        let collector = LineCollector()
        let added = #"{"type":"response.output_item.added","item":{"id":"fc_1","call_id":"call_1","name":"speak","arguments":""}}"#
        let d1 = #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"lines\":[\"Use a hash map.\","}"#
        let d2 = #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\"Track seen values.\"]}"}"#
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\"lines\":[\"Use a hash map.\",\"Track seen values.\"]}"}]}}"#

        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { _ in (sseStream([added, d1, d2, completed]), http(200)) })

        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                             toolChoice: .auto, conversationId: nil,
                                             onLine: { collector.add($0) })

        #expect(collector.lines == ["Use a hash map.", "Track seen values."])
        #expect(resp.toolCalls == [.speak(callId: "call_1", lines: ["Use a hash map.", "Track seen values."])])
    }

    /// capture_screen streams no speak lines; onLine never fires, final response decodes the call.
    @Test func captureScreenStreamsNoLines() async throws {
        let collector = LineCollector()
        let added = #"{"type":"response.output_item.added","item":{"id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":""}}"#
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":"{}"}]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { _ in (sseStream([added, completed]), http(200)) })

        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                            toolChoice: .auto, conversationId: nil,
                                            onLine: { collector.add($0) })

        #expect(collector.lines.isEmpty)
        #expect(resp.toolCalls == [.captureScreen(callId: "call_9")])
    }

    /// The streaming request body sets stream:true.
    @Test func streamingRequestSetsStreamTrue() async throws {
        let box = CapturedBody()
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { req in box.set(req.httpBody); return (sseStream([completed]), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                     toolChoice: .auto, conversationId: nil, onLine: { _ in })
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"stream\":true"))
    }

    /// An incomplete (truncated) streamed response surfaces its reason, like the non-streaming path.
    @Test func streamedIncompleteSurfacesReason() async throws {
        let completed = #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { _ in (sseStream([completed]), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                            toolChoice: .auto, conversationId: nil, onLine: { _ in })
        #expect(resp.incompleteReason == "max_output_tokens")
        #expect(resp.toolCalls.isEmpty)
    }

    /// 429 is retried on the streaming path; a subsequent 200 with a valid stream succeeds.
    @Test func streamingRetriesOn429ThenSucceeds() async throws {
        let attempts = Counter()
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"lines\":[\"hi\"]}"}]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       maxRetries: 3, backoffBaseSeconds: 0,
                                       lineSend: { _ in
            let n = attempts.next()
            return n < 2 ? (sseStream([]), http(429)) : (sseStream([completed]), http(200))
        })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                            toolChoice: .auto, conversationId: nil, onLine: { _ in })
        #expect(resp.toolCalls == [.speak(callId: "c", lines: ["hi"])])
        #expect(attempts.value == 3) // two 429s + one 200
    }
}
