import Foundation
import Testing
@testable import JarvisCore

@Suite struct SpeakArgumentsScannerTests {
    /// A recorded Show code reply: three lines, then a detail with a fence, quotes, and escapes.
    /// The `\u` escape is spliced in from a plain literal so it reaches the file as JSON wrote it.
    static let recorded = #"{"lines":["Sort by start first.","Merge when start "# + "\\u2264"
        + #" last end.","Then append the rest."],"detail":"Use `\"last\"` as the cursor:\n\n```java\nif (cur[0] <= last[1]) {\n    last[1] = Math.max(last[1], cur[1]);\n}\n```"}"#

    private func progress(_ text: String) -> BrainReplyProgress? {
        SpeakArgumentsScanner.progress(in: text)
    }

    private func prefixes(of text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return (0...scalars.count).map { String(String.UnicodeScalarView(scalars[..<$0])) }
    }

    @Test func theWholeReplyReadsAsItsParsedArguments() throws {
        let final = try #require(progress(Self.recorded))
        let parsed = try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: Self.recorded))
        guard case .speak(_, let lines, let detail) = parsed else { Issue.record("expected speak"); return }
        #expect(final.closedLines == lines)
        #expect(final.closedLines[1] == "Merge when start ≤ last end.")
        #expect(final.openLine == nil)
        #expect(final.linesComplete)
        #expect(final.detailMarkdown == detail)
        #expect(final.detailMarkdown?.contains("`\"last\"`") == true)
        #expect(final.detailMarkdown?.contains("\n    last[1]") == true)
    }

    /// Every prefix is a state the wire can leave the scanner in; each must extend the one before.
    @Test func everyPrefixExtendsThePreviousSnapshot() throws {
        let final = try #require(progress(Self.recorded))
        var previous = BrainReplyProgress(closedLines: [], openLine: nil, linesComplete: false, detailMarkdown: nil)
        for prefix in prefixes(of: Self.recorded) {
            let current = try #require(progress(prefix), "prefix \(prefix.count) must yield a snapshot")
            #expect(current.closedLines == Array(final.closedLines.prefix(current.closedLines.count)),
                    "closed lines are always a prefix of the final lines (at \(prefix.count))")
            #expect(current.closedLines.count >= previous.closedLines.count)
            if let open = current.openLine {
                #expect(final.closedLines[current.closedLines.count].hasPrefix(open),
                        "the open line is a prefix of the line it becomes (at \(prefix.count))")
            }
            #expect(!previous.linesComplete || current.linesComplete, "lines never reopen")
            if let detail = current.detailMarkdown {
                #expect(final.detailMarkdown?.hasPrefix(detail) == true)
            }
            previous = current
        }
    }

    @Test func anEscapeSplitAtTheEndIsHeldBackWhole() throws {
        let text = #"{"lines":["Say \"hi\" "# + "\\uD83D\\uDE00" + #" now"]}"#
        func open(_ count: Int) throws -> String? {
            try #require(progress(String(String.UnicodeScalarView(Array(text.unicodeScalars)[..<count])))).openLine
        }
        let quote = try #require(text.range(of: #"\""#)).lowerBound.utf16Offset(in: text)
        #expect(try open(quote + 1) == "Say ", "a lone backslash shows nothing")
        #expect(try open(quote + 2) == "Say \"", "the closed escape shows its character")
        let surrogate = try #require(text.range(of: "\\uD83D")).lowerBound.utf16Offset(in: text)
        #expect(try open(surrogate + 6) == "Say \"hi\" ", "a high surrogate waits for its pair")
        #expect(try open(surrogate + 11) == "Say \"hi\" ", "a partial low surrogate still waits")
        #expect(try open(surrogate + 12) == "Say \"hi\" 😀")
        #expect(try #require(progress(text)).closedLines == ["Say \"hi\" 😀 now"])
    }

    @Test func detailMayArriveBeforeTheLines() throws {
        let text = #"{"detail":"Use a **map**.","lines":["Count first."]}"#
        let midway = try #require(progress(String(text.prefix(#"{"detail":"Use a **m"#.count))))
        #expect(midway.detailMarkdown == "Use a **m")
        #expect(midway.closedLines.isEmpty && midway.openLine == nil && !midway.linesComplete)
        let final = try #require(progress(text))
        #expect(final.detailMarkdown == "Use a **map**.")
        #expect(final.closedLines == ["Count first."])
        #expect(final.linesComplete)
    }

    /// The helper delivers `lines` as a JSON string on some Opus replies; nothing shows early and
    /// the runner's schema re-ask handles the completed call.
    @Test func doubleEncodedLinesYieldNothing() {
        let text = #"{"lines":"[\"a\",\"b\"]","detail":null}"#
        for prefix in prefixes(of: text).dropFirst(#"{"lines":""#.count) {
            #expect(progress(prefix) == nil, "prefix \(prefix.count) must yield nothing")
        }
    }

    @Test func aNullDetailYieldsNoDetail() throws {
        let final = try #require(progress(#"{"lines":["One."],"detail":null}"#))
        #expect(final.detailMarkdown == nil)
        #expect(final.closedLines == ["One."])
        #expect(final.linesComplete)
    }

    @Test func blankLinesAreDroppedAsParseDropsThem() throws {
        let text = #"{"lines":["","   ","Real.","\n"]}"#
        let final = try #require(progress(text))
        #expect(final.closedLines == ["Real."])
        let parsed = ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: text)
        #expect(parsed == .speak(callId: "s", lines: ["Real."]))
    }

    @Test func unknownSiblingKeysAreSkipped() throws {
        let final = try #require(progress(#"{"tone":"warm","meta":{"n":[1,2,{"k":"]"}]},"lines":["A."],"extra":true}"#))
        #expect(final.closedLines == ["A."])
        #expect(final.linesComplete)
    }

    /// A delimiter where a value belongs is malformed; the scanner must stop, not spin.
    @Test func aDelimiterInValuePositionEndsTheScan() throws {
        for text in [#"{"lines":[}"#, #"{"lines":["a"}"#, #"{"lines":[0}"#, #"{"lines":[,}"#, #"{"lines":[true}x"#] {
            let snapshot = try #require(progress(text), "\(text) must yield a snapshot")
            #expect(!snapshot.linesComplete, "\(text) never closed its array")
        }
        #expect(try #require(progress(#"{"lines":["a"}"#)).closedLines == ["a"])
    }

    @Test func nothingYetIsAnEmptySnapshot() throws {
        for prefix in ["", "{", #"{"li"#, #"{"lines""#, #"{"lines":"#, #"{"lines":["#] {
            let snapshot = try #require(progress(prefix))
            #expect(!snapshot.hasText, "prefix \(prefix) shows nothing")
            #expect(!snapshot.linesComplete)
        }
    }
}
