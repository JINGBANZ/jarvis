import Foundation
import Testing
@testable import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // HTTPURLResponse lives here on non-Darwin (Core tests on Linux)
#endif

private func http(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                    statusCode: code, httpVersion: nil, headerFields: headers)!
}

/// Build a Responses body carrying one `speak` function_call whose raw `arguments` string is exactly
/// `arguments`. JSONSerialization handles the wire-escaping, so the test can pass `{}` / `not json`
/// verbatim without hand-escaping quotes.
private func speakResponseBody(arguments: String) -> Data {
    let item: [String: Any] = ["type": "function_call", "id": "f", "call_id": "c",
                               "name": "speak", "arguments": arguments]
    return try! JSONSerialization.data(withJSONObject: ["output": [item]])
}

@Suite struct OpenAIBrainClientTests {
    /// The model returns the overlay lines already split, in a `lines` array — so a line that contains
    /// internal periods/code (e.g. `Array.from(...)`) survives intact as ONE element. This is the
    /// regression that motivated the schema change: client-side sentence splitting used to shatter it.
    @Test func decodesSpeakToolCallWithLinesArray() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\\"lines\\":[\\"Try a hash map.\\",\\"Use `Array.from({length: n + 1}, () => [])` instead.\\"]}"}
        ]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.speak(callId: "call_1",
            lines: ["Try a hash map.", "Use `Array.from({length: n + 1}, () => [])` instead."])])
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

    /// The decoder surfaces the response's ENTIRE `output` array verbatim, so the tool loop can
    /// replay it whole with the tool result (`input.push(...response.output)`) — reasoning id,
    /// encrypted payload, and the function_call's own item id must all survive untouched.
    @Test func decodeSurfacesWholeOutputVerbatim() async throws {
        let json = """
        {"output":[
          {"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque-blob"},
          {"type":"function_call","id":"fc_9","call_id":"call_9","name":"capture_screen","arguments":"{}"}
        ]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.captureScreen(callId: "call_9")])
        #expect(resp.outputItemsJSON.count == 2)
        let reasoning = resp.outputItemsJSON.first ?? ""
        #expect(reasoning.contains(#""id":"rs_1""#))
        #expect(reasoning.contains(#""encrypted_content":"opaque-blob""#))
        let call = resp.outputItemsJSON.last ?? ""
        #expect(call.contains(#""id":"fc_9""#))       // the item id rides along, unlike a rebuilt call
        #expect(call.contains(#""call_id":"call_9""#))
    }

    /// `.rawItems` passthrough is re-emitted into `input` exactly as recorded — reasoning before the
    /// function_call it belongs to, the call keeping its item id — the shape the API requires.
    @Test func encodesRawItemsVerbatimBeforeFunctionCallOutput() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        let convo: [ChatMessage] = [
            .user("transcript"),
            .rawItems([
                #"{"type":"reasoning","id":"rs_1","summary":[]}"#,
                #"{"type":"function_call","id":"fc_1","call_id":"call_1","name":"capture_screen","arguments":"{}"}"#,
            ]),
            .init(role: .tool, text: "screenshot captured", toolCallId: "call_1"),
        ]
        _ = try await client.respond(messages: convo, tools: coachTools)
        let body = try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any]
        let input = body?["input"] as? [[String: Any]] ?? []
        let kinds = input.map { ($0["type"] as? String) ?? ($0["role"] as? String) ?? "?" }
        #expect(kinds == ["user", "reasoning", "function_call", "function_call_output"])
        #expect(input.count == 4 && input[1]["id"] as? String == "rs_1")
        #expect(input.count == 4 && input[2]["id"] as? String == "fc_1")   // verbatim, id preserved
    }

    @Test func decodesStaySilentToolCall() async throws {
        let json = """
        {"output":[
          {"type":"function_call","id":"fc_2","call_id":"call_2","name":"stay_silent","arguments":"{}"}
        ]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls == [.staySilent(callId: "call_2")])
    }

    @Test func noToolCallsMeansSilent() async throws {
        let json = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"(thinking)"}]}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.toolCalls.isEmpty)
    }

    /// `strict:true` makes malformed `speak` arguments unlikely, but the decode must still degrade
    /// gracefully — and an off-contract shape (missing key, non-array value, empty array, broken
    /// JSON) is DROPPED, never accepted as a speak with empty lines: an empty overlay would still
    /// count as a spoken turn (history, counter). The driver treats the empty tool-call list as
    /// silence. Pin that fallback so a future refactor can't silently change it.
    @Test func speakDecodeDropsOffContractArgumentsAsSilence() async throws {
        for args in [#"{}"#, #"{"lines":"hi"}"#, #"{"lines":[]}"#, #"{"lines":["  "]}"#, "not json"] {
            let body = speakResponseBody(arguments: args)
            let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                           send: { _ in (body, http(200)) })
            let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
            #expect(resp.toolCalls.isEmpty, "args=\(args)")
        }
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
        let json = #"{"status":"completed","output":[{"type":"function_call","id":"f","call_id":"c","name":"speak","arguments":"{\"lines\":[\"hi\"]}"}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(resp.incompleteReason == nil)
    }

    /// Plain text output is surfaced (`outputText`) — the whole payload of a tool-less summarizer
    /// call — and multiple text parts are joined.
    @Test func decodesOutputTextForToollessCalls() async throws {
        let json = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"the "},{"type":"output_text","text":"summary"}]}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.4-mini",
                                       send: { _ in (Data(json.utf8), http(200)) })
        let resp = try await client.respond(messages: [.user("condense this")], tools: [])
        #expect(resp.outputText == "the summary")
        #expect(resp.toolCalls.isEmpty)
    }

    /// Any non-2xx fails fast — there is no in-request retry. A failure throws to the driver, which
    /// recovers on the next trigger by re-sending the (still-uncommitted) backlog — fresher than
    /// retrying a stale body in place.
    @Test func httpErrorThrowsWithoutRetry() async {
        let attempts = Counter()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in _ = attempts.next(); return (Data("nope".utf8), http(400)) })
        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        #expect(attempts.value == 1) // single attempt, no retry
    }

    @Test func httpErrorIsClassifiedAtProviderBoundary() async {
        let client = OpenAIBrainClient(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in (Data("unauthorized".utf8), http(401)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected a classified HTTP failure")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .permanent)
            #expect(failure.detail.contains("unauthorized"))
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
    }

    @Test func unknownRequestLocalHTTPErrorPreservesTheSession() async {
        let body = Data(#"{"error":{"code":"future_request_error","type":"future_type"}}"#.utf8)
        let client = OpenAIBrainClient(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in (body, http(422)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected a classified HTTP failure")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .temporary)
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
    }

    @Test func generic404PreservesSessionButModelNotFoundStopsAtProviderBoundary() async {
        let cases: [(Data, BrainFailure.Disposition)] = [
            (Data(#"{"error":{"message":"route unavailable"}}"#.utf8), .temporary),
            (Data(#"{"error":{"code":"model_not_found","type":"invalid_request_error"}}"#.utf8),
             .permanent),
        ]
        for (body, expected) in cases {
            let client = OpenAIBrainClient(
                apiKey: "sk-x", model: "gpt-5.5",
                send: { _ in (body, http(404)) })
            do {
                _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
                Issue.record("expected a classified HTTP failure")
            } catch let failure as BrainFailure {
                #expect(failure.disposition == expected)
            } catch {
                Issue.record("expected BrainFailure, got \(error)")
            }
        }
    }

    @Test func parsedPermanentProviderCodeStopsEvenOnRateLimitStatus() async {
        let body = Data(#"{"error":{"code":"insufficient_quota","type":"billing_error"}}"#.utf8)
        let client = OpenAIBrainClient(
            apiKey: "sk-x", model: "gpt-5.5",
            send: { _ in (body, http(429)) })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected a classified HTTP failure")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .permanent)
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
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
        #expect(body.contains("\"store\":true"))   // requests stay inspectable in the OpenAI logs (debugging)
        #expect(body.contains("\"max_output_tokens\""))
        #expect(body.contains("\"parallel_tool_calls\":false"))
        #expect(body.contains("\"name\":\"capture_screen\""))
    }

    @Test func everySelectableOpenAIModelReusesTheSharedEffort() async throws {
        for model in BrainModelCatalog.models(for: .openAI) {
            for effort in ReasoningEffort.allCases {
                let box = CapturedBody()
                let client = OpenAIBrainClient(
                    apiKey: "sk-x",
                    model: model.id,
                    reasoningEffort: effort.rawValue,
                    maxOutputTokens: effort.maxOutputTokens,
                    send: { request in
                        box.set(request.httpBody)
                        return (Data(#"{"output":[]}"#.utf8), http(200))
                    })
                _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
                let body = try #require(box.get())
                let request = try #require(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(request["model"] as? String == model.id)
                #expect(
                    (request["reasoning"] as? [String: Any])?["effort"] as? String
                        == effort.rawValue)
            }
        }
    }

    /// The caller's `max_output_tokens` budget is encoded verbatim — this is what carries the
    /// per-effort cap (high → 25k) so high-effort reasoning isn't truncated before the tip.
    @Test func encodesProvidedMaxOutputTokens() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5", maxOutputTokens: 25_000,
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"max_output_tokens\":25000"))
    }

    /// A default-constructed client encodes the *default effort's* budget, not a magic number — this
    /// pins the single source of truth (`ReasoningEffort.default.maxOutputTokens`) so the client
    /// default can't silently drift back to a hardcoded value.
    @Test func defaultMaxOutputTokensTracksDefaultEffort() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"max_output_tokens\":\(ReasoningEffort.default.maxOutputTokens)"))
    }

    /// Tools are sent with `strict:true` so the model's function-call arguments are schema-guaranteed
    /// (Structured Outputs via function calling) — that's what lets `speak` return a typed `lines`
    /// array instead of a free-form string the client has to split.
    @Test func encodesStrictToolsForStructuredOutput() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"strict\":true"))
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

    /// `.required` (what audio-driven coach turns use) encodes the Responses "required" string — some
    /// tool call, the model's pick — so a stay-quiet decision must be the stay_silent tool, not text.
    @Test func requiredToolChoiceEncodesRequiredString() async throws {
        let box = CapturedBody()
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { req in box.set(req.httpBody); return (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools, toolChoice: .required)
        let body = String(data: box.get() ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"tool_choice\":\"required\""))
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

    /// With a traffic log wired, a successful round trip lands in `brain-traffic.jsonl` — the raw
    /// eval pipeline input — tagged, with the request body and response body both present.
    @Test func successfulRoundTripIsRecordedToTrafficLog() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       traffic: traffic, trafficTag: "coach",
                                       send: { _ in (Data(#"{"output":[]}"#.utf8), http(200)) })
        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)

        let text = try String(contentsOf: dir.appendingPathComponent(BrainTrafficLog.filename),
                              encoding: .utf8)
        let entry = try #require(try JSONSerialization.jsonObject(
            with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(entry["tag"] as? String == "coach")
        #expect(entry["status"] as? Int == 200)
        #expect((entry["request"] as? [String: Any])?["model"] as? String == "gpt-5.5")
        #expect(entry["response"] != nil)
    }

    /// A transport failure still records the attempt (request + error, no response) and rethrows.
    @Test func transportErrorIsRecordedToTrafficLogAndRethrown() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       traffic: traffic, trafficTag: "coach",
                                       send: { _ in throw URLError(.timedOut) })
        await #expect(throws: (any Error).self) {
            try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        let text = try String(contentsOf: dir.appendingPathComponent(BrainTrafficLog.filename),
                              encoding: .utf8)
        let entry = try #require(try JSONSerialization.jsonObject(
            with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(entry["error"] != nil)
        #expect(entry["response"] == nil)
        #expect((entry["request"] as? [String: Any])?["model"] as? String == "gpt-5.5")
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
