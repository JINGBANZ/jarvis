import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct MessagesStreamDecoderTests {
    let wire = MessagesWireFormat(model: "claude-opus-5", reasoningEffort: "low", maxOutputTokens: 2_048, stream: true)

    /// The reply the unstreamed route returns for the event log below.
    static let unstreamed = #"""
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5",
     "content":[{"type":"thinking","thinking":"","signature":"EmcKZQER"},
                {"type":"tool_use","id":"toolu_01","name":"speak","input":{"lines":["Try a hash map."],"detail":null}}],
     "stop_reason":"tool_use","stop_sequence":null,
     "usage":{"input_tokens":20,"cache_read_input_tokens":3360,"cache_creation_input_tokens":0,"output_tokens":60}}
    """#

    static let log: [ServerSentEvent] = [
        .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":20,"cache_read_input_tokens":3360,"cache_creation_input_tokens":0,"output_tokens":1}}}"#),
        .init(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
        .init(event: "ping", data: #"{"type":"ping"}"#),
        .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#),
        .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EmcKZQER"}}"#),
        .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
        .init(event: "content_block_start", data: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"speak","input":{}}}"#),
        .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}"#),
        .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"lines\":[\"Try a"}}"#),
        .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" hash map.\"],"}}"#),
        .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"detail\":null}"}}"#),
        .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":1}"#),
        .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":60}}"#),
        .init(event: "message_stop", data: #"{"type":"message_stop"}"#),
    ]

    private func run(_ events: [ServerSentEvent]) throws -> (deltas: [ToolCallDelta], body: Data) {
        var decoder = try #require(wire.makeStreamDecoder())
        var deltas: [ToolCallDelta] = []
        for event in events {
            if let delta = try decoder.receive(event) { deltas.append(delta) }
        }
        return (deltas, try decoder.finish())
    }

    @Test func assemblesTheMessageTheUnstreamedRouteReturns() throws {
        let (deltas, body) = try run(Self.log)
        #expect(deltas == [
            ToolCallDelta(index: 0, name: "speak", arguments: ""),
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a"#),
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a hash map."],"#),
            ToolCallDelta(index: 0, name: "speak", arguments: #"{"lines":["Try a hash map."],"detail":null}"#),
        ])
        let recorded = try JSONSerialization.jsonObject(with: body) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(Self.unstreamed.utf8)) as? NSDictionary
        #expect(recorded == original)
        let streamed = try wire.decode(body)
        let expected = try wire.decode(Data(Self.unstreamed.utf8))
        #expect(streamed.toolCalls == [.speak(callId: "toolu_01", lines: ["Try a hash map."])])
        #expect(streamed.rawToolCalls == expected.rawToolCalls)
        #expect(streamed.outputItemsJSON.count == 2)
        #expect(streamed.outputItemsJSON[0].contains(#""signature":"EmcKZQER""#))
        #expect(streamed.incompleteReason == nil)
    }

    @Test func textDeltasBecomeTheReplyText() throws {
        let (deltas, body) = try run([
            .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"msg_02","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":5,"output_tokens":1}}}"#),
            .init(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The user "}}"#),
            .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"outlined a hash map."}}"#),
            .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
            .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}"#),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#),
        ])
        #expect(deltas.isEmpty)
        let response = try wire.decode(body)
        #expect(response.outputText == "The user outlined a hash map.")
        #expect(response.toolCalls.isEmpty)
    }

    @Test func aCutOffInputReadsAsTruncation() throws {
        let cut = Array(Self.log.prefix(10)) + [
            .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":1}"#),
            .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":12}}"#),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#),
        ]
        let response = try wire.decode(try run(cut).body)
        #expect(response.incompleteReason == "max_tokens")
        #expect(response.toolCalls.isEmpty)
    }

    @Test func anErrorEventIsAStreamFailureCarryingTheEvent() throws {
        var decoder = try #require(wire.makeStreamDecoder())
        _ = try decoder.receive(Self.log[0])
        let event = ServerSentEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        do {
            _ = try decoder.receive(event)
            Issue.record("expected the error event to fail the stream")
        } catch let failure as StreamFailure {
            #expect(failure.errorBody == Data(event.data.utf8))
        }
    }

    @Test func aStreamWithoutMessageStopFailsWithNoBody() throws {
        var decoder = try #require(wire.makeStreamDecoder())
        for event in Self.log.dropLast() { _ = try decoder.receive(event) }
        do {
            _ = try decoder.finish()
            Issue.record("expected the missing message_stop to fail the stream")
        } catch let failure as StreamFailure {
            #expect(failure.errorBody == nil)
        }
    }
}
