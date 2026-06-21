import Foundation
import Testing
@testable import JarvisCore

private func http(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                    statusCode: code, httpVersion: nil, headerFields: headers)!
}

/// Build an SSE line stream from scripted `data:` payloads (the wire `event:` lines are optional —
/// the client switches on the JSON `type`, so we only need the data lines plus blank separators).
private func sseStream(_ dataLines: [String]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for d in dataLines { continuation.yield("data: \(d)"); continuation.yield("") }
        continuation.finish()
    }
}

/// A stream that yields a partial line then throws — to exercise the streaming error-body drain's
/// do/catch (a 429 whose body connection drops mid-drain).
private func throwingStream() -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield("data: partial error body")
        continuation.finish(throwing: NSError(domain: "test", code: -99))
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
        let added = #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":""}}"#
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
        let added = #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":""}}"#
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

    /// A small `Retry-After` header is honoured *over* a large computed backoff. With
    /// `backoffBaseSeconds` high, an ignored header would impose a multi-second wait; reading
    /// `Retry-After: 0` makes the retry near-instant. Asserting the call completes well under that
    /// backoff proves the header is actually read — which the `backoffBaseSeconds: 0` retry test above
    /// cannot (its delay is 0 either way). Adapts to the code via a generous wall-clock margin rather
    /// than adding a clock seam to production.
    @Test func streamingHonoursRetryAfterOverComputedBackoff() async throws {
        let attempts = Counter()
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"lines\":[\"hi\"]}"}]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       maxRetries: 3, backoffBaseSeconds: 10,  // ignored header => >=10s wait
                                       lineSend: { _ in
            let n = attempts.next()
            return n < 2
                ? (sseStream([]), http(429, headers: ["Retry-After": "0"]))
                : (sseStream([completed]), http(200))
        })
        let clock = ContinuousClock()
        let start = clock.now
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                            toolChoice: .auto, conversationId: nil, onLine: { _ in })
        let elapsed = clock.now - start
        #expect(resp.toolCalls == [.speak(callId: "c", lines: ["hi"])])
        #expect(attempts.value == 3)        // two 429s + one 200
        #expect(elapsed < .seconds(2))      // Retry-After:0 honoured, not the ~10s+ computed backoff
    }

    /// A terminal `response.failed` event must surface as a thrown error (→ CoachDriver `.brainError`),
    /// NOT decode to an empty response that's indistinguishable from a deliberate stay-silent turn.
    @Test func streamedFailedEventThrows() async {
        let failed = #"{"type":"response.failed","response":{"status":"failed","error":{"message":"server boom"},"output":[]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { _ in (sseStream([failed]), http(200)) })
        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                         toolChoice: .auto, conversationId: nil, onLine: { _ in })
        }
    }

    /// A 429 whose error-body stream THROWS mid-drain must not escape the retry loop: the drain's
    /// do/catch swallows it and the client still retries and succeeds on the next attempt.
    @Test func streamingRetriesWhen429BodyDrainThrows() async throws {
        let attempts = Counter()
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"lines\":[\"hi\"]}"}]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       maxRetries: 3, backoffBaseSeconds: 0,
                                       lineSend: { _ in
            let n = attempts.next()
            return n < 1 ? (throwingStream(), http(429)) : (sseStream([completed]), http(200))
        })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                            toolChoice: .auto, conversationId: nil, onLine: { _ in })
        #expect(resp.toolCalls == [.speak(callId: "c", lines: ["hi"])])
        #expect(attempts.value == 2)   // 429 (drain threw, was swallowed) → retry → 200
    }

    /// An output_item.added with NO `type` is still treated as a function_call (the forward-compat
    /// default), so its speak deltas stream — exercises the default-when-absent branch of the guard.
    @Test func streamsLinesWhenItemTypeMissing() async throws {
        let collector = LineCollector()
        let added = #"{"type":"response.output_item.added","item":{"id":"fc_1","call_id":"call_1","name":"speak","arguments":""}}"#
        let d = #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"lines\":[\"hi\"]}"}"#
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\"lines\":[\"hi\"]}"}]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { _ in (sseStream([added, d, completed]), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                     toolChoice: .auto, conversationId: nil, onLine: { collector.add($0) })
        #expect(collector.lines == ["hi"])
    }

    /// An output_item.added whose `type` is NOT function_call (e.g. a reasoning/message item that
    /// happens to carry a `name`) is rejected, so its deltas never feed the speak parser — exercises
    /// the reject-on-mismatch branch of the guard.
    @Test func ignoresDeltasForNonFunctionCallItem() async throws {
        let collector = LineCollector()
        let bogus = #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1","name":"speak","arguments":""}}"#
        let bogusDelta = #"{"type":"response.function_call_arguments.delta","item_id":"rs_1","delta":"{\"lines\":[\"leak\"]}"}"#
        let completed = #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
            lineSend: { _ in (sseStream([bogus, bogusDelta, completed]), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools,
                                     toolChoice: .auto, conversationId: nil, onLine: { collector.add($0) })
        #expect(collector.lines.isEmpty)   // the non-function_call item's name was not mapped
    }
}
