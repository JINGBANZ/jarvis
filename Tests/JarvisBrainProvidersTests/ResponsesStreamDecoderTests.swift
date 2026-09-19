import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct ResponsesStreamDecoderTests {
    let wire = ResponsesWireFormat(
        model: "gpt-5.5", reasoningEffort: "low", maxOutputTokens: 2_048, store: true, stream: true)

    static let terminalResponse = #"""
    {"id":"resp_1","object":"response","status":"completed","incomplete_details":null,
     "output":[{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque"},
               {"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\"lines\":[\"Try a hash map.\"],\"detail\":null}"}],
     "usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":4},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}}
    """#

    /// A recorded reply's event log: reasoning first, then the speak call written in two pieces.
    static let log: [ServerSentEvent] = [
        .init(event: "response.created", data: #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress","output":[]}}"#),
        .init(event: "response.output_item.added", data: #"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}"#),
        .init(event: "response.output_item.done", data: #"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque"}}"#),
        .init(event: "response.output_item.added", data: #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":""}}"#),
        .init(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"{\"lines\":[\"Try a ","sequence_number":5}"#),
        .init(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"hash map.\"],\"detail\":null}","sequence_number":6}"#),
        .init(event: "response.function_call_arguments.done", data: #"{"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":1,"arguments":"{\"lines\":[\"Try a hash map.\"],\"detail\":null}"}"#),
        .init(event: "response.output_item.done", data: #"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"speak","arguments":"{\"lines\":[\"Try a hash map.\"],\"detail\":null}"}}"#),
        .init(event: "response.completed", data: #"{"type":"response.completed","sequence_number":9,"response":"# + terminalResponse + "}"),
    ]

    private func run(_ events: [ServerSentEvent]) throws -> (deltas: [ToolCallDelta], body: Data) {
        var decoder = try #require(wire.makeStreamDecoder())
        var deltas: [ToolCallDelta] = []
        for event in events {
            if let delta = try decoder.receive(event) { deltas.append(delta) }
        }
        return (deltas, try decoder.finish())
    }

    @Test func forwardsArgumentDeltasAndEndsWithTheTerminalResponse() throws {
        let (deltas, body) = try run(Self.log)
        #expect(deltas == [
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a "#),
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a hash map."],"detail":null}"#),
        ])
        let streamed = try wire.decode(body)
        let unstreamed = try wire.decode(Data(Self.terminalResponse.utf8))
        #expect(streamed.toolCalls == unstreamed.toolCalls)
        #expect(streamed.toolCalls == [.speak(callId: "call_1", lines: ["Try a hash map."])])
        #expect(streamed.rawToolCalls == unstreamed.rawToolCalls)
        #expect(streamed.incompleteReason == nil && unstreamed.incompleteReason == nil)
        // Re-serialized items carry their keys in any order; the provider re-parses them on replay.
        func items(_ response: BrainResponse) -> [NSDictionary?] {
            response.outputItemsJSON.map { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
        }
        #expect(items(streamed) == items(unstreamed))
        #expect(items(streamed).count == 2 && items(streamed).allSatisfy { $0 != nil })
        let recorded = try JSONSerialization.jsonObject(with: body) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(Self.terminalResponse.utf8)) as? NSDictionary
        #expect(recorded == original)
    }

    @Test func aSecondCallCountsFromTheFirstCallNotTheOutputIndex() throws {
        let second: [ServerSentEvent] = [
            .init(event: "response.output_item.added", data: #"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"stay_silent","arguments":""}}"#),
            .init(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_2","output_index":2,"delta":"{}","sequence_number":8}"#),
        ]
        let (deltas, _) = try run(Array(Self.log.dropLast()) + second + [Self.log.last!])
        #expect(deltas.last == ToolCallDelta(index: 1, name: "stay_silent", arguments: "{}"))
    }

    @Test func anIncompleteTerminalEventKeepsItsReason() throws {
        let incomplete = ServerSentEvent(
            event: "response.incomplete",
            data: #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}}"#)
        let (_, body) = try run([incomplete])
        #expect(try wire.decode(body).incompleteReason == "max_output_tokens")
    }

    @Test func aFailedResponseOrErrorEventIsAStreamFailureWithTheErrorObject() throws {
        func errorObject(_ event: ServerSentEvent) throws -> [String: Any]? {
            var decoder = try #require(wire.makeStreamDecoder())
            do {
                _ = try decoder.receive(event)
                Issue.record("expected the event to fail the stream")
                return nil
            } catch let failure as StreamFailure {
                let body = try #require(failure.errorBody)
                return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
            }
        }
        let failed = try errorObject(.init(
            event: "response.failed",
            data: #"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"upstream"}}}"#))
        #expect(failed?["code"] as? String == "server_error")
        // OpenAI's own event is flat; the helper's nests the detail under `error`.
        let flat = try errorObject(.init(
            event: "error", data: #"{"type":"error","code":"rate_limit_exceeded","message":"slow down","param":null,"sequence_number":3}"#))
        #expect(flat?["code"] as? String == "rate_limit_exceeded")
        #expect(flat?["message"] as? String == "slow down")
        let nested = try errorObject(.init(
            event: "error", data: #"{"type":"error","error":{"type":"server_error","code":"internal_server_error","message":"upstream stream closed"},"sequence_number":4}"#))
        #expect(nested?["code"] as? String == "internal_server_error")
    }

    @Test func aStreamWithoutATerminalEventFailsWithNoBody() throws {
        var decoder = try #require(wire.makeStreamDecoder())
        for event in Self.log.dropLast() { _ = try decoder.receive(event) }
        do {
            _ = try decoder.finish()
            Issue.record("expected the missing terminal event to fail the stream")
        } catch let failure as StreamFailure {
            #expect(failure.errorBody == nil)
        }
    }
}
