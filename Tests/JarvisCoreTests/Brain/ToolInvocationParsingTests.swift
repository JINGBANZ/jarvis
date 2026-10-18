import Foundation
import Testing
@testable import JarvisCore

@Suite struct ToolInvocationParsingTests {
    @Test func callToolResolvesToTheNamedToolFromArgumentsText() {
        let parsed = ToolInvocation.parse(
            callId: "c1", name: "call_tool",
            argumentsJSON: #"{"name":"search_references","arguments":"{\"query\":\"rate limiter\"}"}"#)
        #expect(parsed == .searchReferences(callId: "c1", query: "rate limiter"))
    }

    @Test func callToolAlsoAcceptsAnArgumentsObject() {
        let parsed = ToolInvocation.parse(
            callId: "c1", name: "call_tool",
            argumentsJSON: #"{"name":"search_references","arguments":{"query":"rate limiter"}}"#)
        #expect(parsed == .searchReferences(callId: "c1", query: "rate limiter"))
    }

    @Test(arguments: ["speak", "capture_screen", "stay_silent", "load_tool", "load_skill", "call_tool"])
    func callToolRefusesToRouteAFixedTool(name: String) {
        let parsed = ToolInvocation.parse(
            callId: "c1", name: "call_tool",
            argumentsJSON: #"{"name":"\#(name)","arguments":"{\"hint\":\"x\"}"}"#)
        #expect(parsed == nil)
    }

    @Test func callToolWithAnUnknownNameOrUnusableArgumentsIsMalformed() {
        #expect(ToolInvocation.parse(callId: "c1", name: "call_tool",
                                     argumentsJSON: #"{"name":"nope","arguments":"{}"}"#) == nil)
        #expect(ToolInvocation.parse(callId: "c1", name: "call_tool",
                                     argumentsJSON: #"{"name":"search_references"}"#) == nil)
        #expect(ToolInvocation.parse(callId: "c1", name: "call_tool",
                                     argumentsJSON: #"{"name":"search_references","arguments":"not json"}"#) == nil)
    }

    @Test func theRoutedNameIsReadableWithoutTheRoutedArguments() {
        #expect(ToolInvocation.routedToolName(
            argumentsJSON: #"{"name":"search_references","arguments":"{}"}"#) == "search_references")
        #expect(ToolInvocation.routedToolName(argumentsJSON: #"{"arguments":"{}"}"#) == nil)
    }

    @Test func parsingIsByNameAloneSoARoutedNameParsesLikeADirectOne() {
        let parsed = ToolInvocation.parse(
            callId: "p1", name: "search_references", argumentsJSON: #"{"query":"q"}"#)
        #expect(parsed == .searchReferences(callId: "p1", query: "q"))
    }
    @Test func readPrepNoteArgumentsAreValidatedThroughDispatcher() {
        let valid = ToolInvocation.parse(callId: "read", name: "call_tool",
            argumentsJSON: #"{"name":"read_reference","arguments":{"document_id":"00000000-0000-0000-0000-000000000001","offset":0}}"#)
        #expect(valid != nil)
        for arguments in [
            #"{"document_id":"","offset":0}"#,
            #"{"document_id":"00000000-0000-0000-0000-000000000001","offset":-1}"#,
            #"{"document_id":"00000000-0000-0000-0000-000000000001","offset":1.5}"#,
            #"{"document_id":"00000000-0000-0000-0000-000000000001","offset":true}"#,
            #"{"document_id":"00000000-0000-0000-0000-000000000001","offset":"zero"}"#,
        ] {
            #expect(ToolInvocation.parse(callId: "read", name: "read_reference",
                                        argumentsJSON: arguments) == nil)
        }
    }

}
