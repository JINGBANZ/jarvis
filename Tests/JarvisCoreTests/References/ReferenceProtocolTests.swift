import Foundation
import Testing
@testable import JarvisCore

struct ReferenceProtocolTests {
    @Test func splitAndCoalescedFrames() throws {
        let a = Data("{\"id\":1}".utf8)
        let frame = try ReferenceFrame.encode(a)
        var decoder = ReferenceFrame()
        #expect(try decoder.append(frame.prefix(3)).isEmpty)
        #expect(try decoder.append(frame.dropFirst(3) + frame) == [a, a])
        try decoder.finish()
    }
    @Test func invalidLengthAndPartialEOF() throws {
        var decoder = ReferenceFrame()
        #expect(throws: ReferenceProtocolError.oversized) {
            try decoder.append(Data([0, 32, 0, 0]))
        }
        decoder = ReferenceFrame()
        _ = try decoder.append(Data([0, 0]))
        #expect(throws: ReferenceProtocolError.truncated) { try decoder.finish() }
    }
    @Test func malformedReplies() throws {
        for body in ["invalid", "{}", "{\"protocol\":2}", "{\"protocol\":true}"] {
            #expect(throws: ReferenceProtocolError.malformed) { try ReferenceReply(Data(body.utf8)) }
        }
        let id = UUID()
        let body = Data("{\"protocol\":1,\"id\":\"\(id)\",\"status\":\"ok\",\"result\":{}}".utf8)
        #expect(try ReferenceReply(body).id == id)
    }
    @Test func outOfOrderCancelDuplicateAndUnknown() throws {
        var state = ReferenceRequestState()
        let a = UUID(), b = UUID()
        try state.begin(a); try state.begin(b)
        #expect(try state.receive(b))
        state.cancel(a)
        #expect(try !state.receive(a))
        #expect(throws: ReferenceProtocolError.unexpectedResponse) { try state.receive(a) }
        #expect(throws: ReferenceProtocolError.unexpectedResponse) { try state.receive(UUID()) }
    }
}
