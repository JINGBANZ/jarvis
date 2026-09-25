import Foundation
import Testing
import JarvisBrainProviders
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// @unchecked: `lock` guards the deltas, which the sink appends from the transport's reading task.
private final class DeltaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolCallDelta] = []
    var deltas: [ToolCallDelta] { lock.withLock { stored } }
    func append(_ delta: ToolCallDelta) { lock.withLock { stored.append(delta) } }
}

@Suite struct BrainAccessorStreamingTests {
    private func http(_ code: Int, contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1:4555/v1/messages")!, statusCode: code,
                        httpVersion: nil, headerFields: ["Content-Type": contentType])!
    }

    /// The wire's chunks, in the order and pieces the sender delivers them.
    private func streaming(_ chunks: [String], contentType: String = "text/event-stream",
                           status: Int = 200) -> BrainAccessor.Sender {
        let http = http(status, contentType: contentType)
        return { _ in
            (AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
                continuation.finish()
            }, http)
        }
    }

    private static let claudeEvents = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":20,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"speak","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"lines\\":[\\"Try a"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" hash map.\\"],\\"detail\\":null}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test func aStreamedReplyReachesTheSinkAndDecodesLikeTheWholeBody() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = await FileSessionAudit.readyForTesting(directory: dir)
        // Split mid-event and mid-line to prove the framing is chunk-independent.
        let text = Self.claudeEvents
        let cut = text.index(text.startIndex, offsetBy: 300)
        let box = CapturedBody()
        let deltas = DeltaBox()
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5",
            stream: true, traffic: traffic, trafficTag: "coach",
            send: { request in
                box.set(request.httpBody)
                return try await self.streaming([String(text[..<cut]), String(text[cut...])])(request)
            })
        let conversation = try await client.makeConversation { delta in
            deltas.append(delta)
            return delta.arguments.contains("Try") ? ["first_speak_text_ms"] : []
        }
        let response = try await conversation.respond(
            messages: [.user("hi")], tools: coachTools, toolChoice: .auto)
        _ = await traffic.closeForTesting()

        #expect(response.toolCalls == [.speak(callId: "toolu_01", lines: ["Try a hash map."])])
        #expect(response.outputItemsJSON.count == 1)
        #expect(deltas.deltas == [
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a"#),
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a hash map."],"detail":null}"#),
        ])
        let request = try #require(try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any])
        #expect(request["stream"] as? Bool == true)
        #expect((request["tools"] as? [[String: Any]])?.allSatisfy { $0["eager_input_streaming"] as? Bool == true } == true)

        let text2 = try String(contentsOf: dir.appendingPathComponent(FileSessionAudit.brainTrafficFilename), encoding: .utf8)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(text2.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(entry["status"] as? Int == 200)
        let recorded = try #require(entry["response"] as? [String: Any])
        #expect(recorded["type"] as? String == "message")
        #expect(recorded["stop_reason"] as? String == "tool_use")
        #expect((recorded["content"] as? [[String: Any]])?.first?["name"] as? String == "speak")
        let phases = try #require(entry["phases"] as? [String: Int])
        #expect(phases["first_event_ms"] != nil)
        #expect(phases["first_speak_text_ms"] != nil)
    }

    @Test func aReplyWithoutAnEventStreamIsDecodedWhole() async throws {
        let deltas = DeltaBox()
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5", stream: true,
            send: streaming([#"{"type":"message","content":[{"type":"tool_use","id":"t1","name":"speak","input":{"lines":["Whole."]}}],"stop_reason":"tool_use"}"#],
                            contentType: "application/json"))
        let conversation = try await client.makeConversation { delta in deltas.append(delta); return [] }
        let response = try await conversation.respond(
            messages: [.user("hi")], tools: coachTools, toolChoice: .auto)
        #expect(response.toolCalls == [.speak(callId: "t1", lines: ["Whole."])])
        #expect(deltas.deltas.isEmpty)
    }

    @Test func theEagerFieldGoesOnlyOnStreamedClaudeTools() async throws {
        func tools(provider: BrainProvider, stream: Bool) async throws -> [[String: Any]] {
            let box = CapturedBody()
            let reply = provider == .claudeSubscription
                ? #"{"type":"message","content":[],"stop_reason":"end_turn"}"# : #"{"output":[]}"#
            let ok = http(200, contentType: "application/json")
            let client = BrainAccessor(
                provider: provider, apiKey: "k", model: provider == .claudeSubscription ? "claude-opus-5" : "gpt-5.5",
                stream: stream,
                send: sending { request in box.set(request.httpBody); return (Data(reply.utf8), ok) })
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            let body = try #require(try JSONSerialization.jsonObject(with: box.get() ?? Data()) as? [String: Any])
            #expect(body["stream"] as? Bool == (stream ? true : nil))
            return try #require(body["tools"] as? [[String: Any]])
        }
        #expect(try await tools(provider: .claudeSubscription, stream: true).allSatisfy { $0["eager_input_streaming"] as? Bool == true })
        #expect(try await tools(provider: .claudeSubscription, stream: false).allSatisfy { $0["eager_input_streaming"] == nil })
        #expect(try await tools(provider: .openAI, stream: true).allSatisfy { $0["eager_input_streaming"] == nil })
    }

    @Test func anErrorEventIsClassifiedByTheTargetsTable() async {
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5", stream: true,
            send: streaming([
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"type\":\"message\",\"content\":[],\"usage\":{}}}\n\n",
                "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
            ]))
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected the error event to fail the reply")
        } catch let failure as ProviderFailure {
            #expect(failure.source == .brain(.claudeSubscription))
            #expect(failure.stage == .response)
            #expect(failure.category == .unavailable && failure.disposition == .temporary)
            #expect(failure.identity.errorType == "overloaded_error")
            #expect(failure.message == "Overloaded")
        } catch {
            Issue.record("expected a ProviderFailure, got \(error)")
        }
    }

    @Test func aStreamThatClosesBeforeItsTerminalEventFailsTemporarily() async {
        let client = BrainAccessor(
            provider: .openAI, apiKey: "sk-x", model: "gpt-5.5", stream: true,
            send: streaming([
                "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"status\":\"in_progress\",\"output\":[]}}\n\n",
            ]))
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected the closed stream to fail the reply")
        } catch let failure as ProviderFailure {
            #expect(failure.stage == .response)
            #expect(failure.category == .response && failure.disposition == .temporary)
        } catch {
            Issue.record("expected a ProviderFailure, got \(error)")
        }
    }

    /// The terminal event ends the reply; a connection that then stalls instead of closing must not
    /// cost the reply its deadline.
    @Test func theReplyReturnsAtItsTerminalEventEvenIfTheConnectionStaysOpen() async throws {
        let http = http(200, contentType: "text/event-stream")
        let client = BrainAccessor(
            provider: .claudeSubscription, apiKey: "proxy-key", model: "claude-opus-5",
            timeout: 10, stream: true,
            send: { _ in
                (AsyncThrowingStream { continuation in
                    // The wire ends every event with a blank line; the literal above drops the last.
                    continuation.yield(Data((Self.claudeEvents + "\n").utf8))
                    // Never finished: the connection stays open after message_stop.
                }, http)
            })
        let started = ContinuousClock.now
        let response = try await client.respond(messages: [.user("hi")], tools: coachTools)
        #expect(response.toolCalls == [.speak(callId: "toolu_01", lines: ["Try a hash map."])])
        #expect(started.duration(to: .now) < .seconds(5), "the reply did not wait for the deadline")
    }

    /// `timeoutInterval` bounds the wait between bytes; a reply that keeps trickling ends at the
    /// same total deadline, and records like any other timeout.
    @Test func theWholeReplyIsBoundedByTheWorkloadTimeout() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = await FileSessionAudit.readyForTesting(directory: dir)
        let http = http(200, contentType: "text/event-stream")
        let client = BrainAccessor(
            provider: .openAI, apiKey: "sk-x", model: "gpt-5.5", timeout: 0.3, stream: true,
            traffic: traffic, trafficTag: "coach",
            send: { _ in
                (AsyncThrowingStream { continuation in
                    let ticking = Task {
                        while !Task.isCancelled {
                            continuation.yield(Data(": tick\n\n".utf8))
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    }
                    continuation.onTermination = { _ in ticking.cancel() }
                }, http)
            })
        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected the deadline to end the reply")
        } catch let failure as ProviderFailure {
            #expect(failure.category == .timeout && failure.disposition == .temporary)
        } catch {
            Issue.record("expected a ProviderFailure, got \(error)")
        }
        _ = await traffic.closeForTesting()
        let text = try String(contentsOf: dir.appendingPathComponent(FileSessionAudit.brainTrafficFilename), encoding: .utf8)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect((entry["error"] as? String)?.contains("error_code=\(URLError.timedOut.rawValue)") == true)
        #expect(entry["response"] == nil)
    }
}
