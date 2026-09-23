import Foundation
import Testing
@testable import JarvisCore

@Suite struct ToolInvocationParsingTests {
    @Test func callToolResolvesToTheNamedToolFromArgumentsText() {
        let parsed = ToolInvocation.parse(
            callId: "c1", name: "call_tool",
            argumentsJSON: #"{"name":"search_prep_notes","arguments":"{\"query\":\"rate limiter\"}"}"#)
        #expect(parsed == .searchPrepNotes(callId: "c1", query: "rate limiter"))
    }

    @Test func callToolAlsoAcceptsAnArgumentsObject() {
        let parsed = ToolInvocation.parse(
            callId: "c1", name: "call_tool",
            argumentsJSON: #"{"name":"search_prep_notes","arguments":{"query":"rate limiter"}}"#)
        #expect(parsed == .searchPrepNotes(callId: "c1", query: "rate limiter"))
    }

    @Test(arguments: ["speak", "capture_screen", "stay_silent", "load_tool", "load_skill", "call_tool"])
    func callToolRefusesToRouteAFixedTool(name: String) {
        let parsed = ToolInvocation.parse(
            callId: "c1", name: "call_tool",
            argumentsJSON: #"{"name":"\#(name)","arguments":"{\"lines\":[\"x\"]}"}"#)
        #expect(parsed == nil)
    }

    @Test func callToolWithAnUnknownNameOrUnusableArgumentsIsMalformed() {
        #expect(ToolInvocation.parse(callId: "c1", name: "call_tool",
                                     argumentsJSON: #"{"name":"nope","arguments":"{}"}"#) == nil)
        #expect(ToolInvocation.parse(callId: "c1", name: "call_tool",
                                     argumentsJSON: #"{"name":"search_prep_notes"}"#) == nil)
        #expect(ToolInvocation.parse(callId: "c1", name: "call_tool",
                                     argumentsJSON: #"{"name":"search_prep_notes","arguments":"not json"}"#) == nil)
    }

    @Test func theRoutedNameIsReadableWithoutTheRoutedArguments() {
        #expect(ToolInvocation.routedToolName(
            argumentsJSON: #"{"name":"search_prep_notes","arguments":"{}"}"#) == "search_prep_notes")
        #expect(ToolInvocation.routedToolName(argumentsJSON: #"{"arguments":"{}"}"#) == nil)
    }

    @Test func parsingIsByNameAloneSoARoutedNameParsesLikeADirectOne() {
        let parsed = ToolInvocation.parse(
            callId: "p1", name: "search_prep_notes", argumentsJSON: #"{"query":"q"}"#)
        #expect(parsed == .searchPrepNotes(callId: "p1", query: "q"))
    }
}
