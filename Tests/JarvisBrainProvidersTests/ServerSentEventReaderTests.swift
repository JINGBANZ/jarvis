import Foundation
import Testing
@testable import JarvisBrainProviders

@Suite struct ServerSentEventReaderTests {
    private func events(_ chunks: String...) -> [ServerSentEvent] {
        var reader = ServerSentEventReader()
        var events = chunks.flatMap { reader.receive(Data($0.utf8)) }
        if let trailing = reader.finish() { events.append(trailing) }
        return events
    }

    @Test func splitsAnEventAcrossChunkBoundaries() {
        #expect(events("event: message_st", "art\ndata: {\"a\"", ":1}\n\n") == [
            ServerSentEvent(event: "message_start", data: #"{"a":1}"#),
        ])
    }

    @Test func joinsDataLinesWithNewlinesAndKeepsEventOrder() {
        #expect(events("data: one\ndata: two\n\nevent: e\ndata: three\n\n") == [
            ServerSentEvent(event: nil, data: "one\ntwo"),
            ServerSentEvent(event: "e", data: "three"),
        ])
    }

    @Test func ignoresCommentsIdsAndCarriageReturns() {
        #expect(events(": keep-alive\r\n\r\nid: 7\r\nevent: ping\r\ndata: {}\r\n\r\n") == [
            ServerSentEvent(event: "ping", data: "{}"),
        ])
    }

    @Test func aBlankLineWithoutDataDispatchesNothing() {
        #expect(events("\n\nevent: lonely\n\n").isEmpty)
    }

    @Test func flushesATrailingEventWithNoBlankLine() {
        #expect(events("event: message_stop\ndata: {\"type\":\"message_stop\"}") == [
            ServerSentEvent(event: "message_stop", data: #"{"type":"message_stop"}"#),
        ])
    }

    @Test func keepsMultibyteCharactersWhole() {
        let text = "data: {\"t\":\"日本語 ✓\"}\n\n"
        let bytes = Array(text.utf8)
        // Split inside the three-byte character.
        let first = Data(bytes[..<12]), second = Data(bytes[12...])
        #expect(events(String(decoding: first, as: UTF8.self) + String(decoding: second, as: UTF8.self)).count == 1)
        var reader = ServerSentEventReader()
        let received = reader.receive(first) + reader.receive(second)
        #expect(received == [ServerSentEvent(event: nil, data: #"{"t":"日本語 ✓"}"#)])
    }
}
