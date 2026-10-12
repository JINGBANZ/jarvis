import Foundation
import Testing
@testable import JarvisCore

@Suite struct SpeakArgumentsScannerTests {
    /// A Show code reply: one hint, then a detail with a fence, quotes, and escapes.
    /// The `\u` escape is spliced in from a plain literal so it reaches the file as JSON wrote it.
    static let recorded = #"{"hint":"Sort by start first. Merge when start "# + "\\u2264"
        + #" last end. Then append the rest.","detail":"Use `\"last\"` as the cursor:\n\n```java\nif (cur[0] <= last[1]) {\n    last[1] = Math.max(last[1], cur[1]);\n}\n```"}"#

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
        guard case .speak(_, let hint, let detail) = parsed else { Issue.record("expected speak"); return }
        #expect(final.hint == hint)
        #expect(final.hint.contains("Merge when start ≤ last end."))
        #expect(final.hintComplete)
        #expect(final.detailMarkdown == detail)
        #expect(final.detailMarkdown?.contains("`\"last\"`") == true)
        #expect(final.detailMarkdown?.contains("\n    last[1]") == true)
    }

    /// Every prefix is a state the wire can leave the scanner in; each must extend the one before.
    @Test func everyPrefixExtendsThePreviousSnapshot() throws {
        let final = try #require(progress(Self.recorded))
        var previous = BrainReplyProgress(hint: "", hintComplete: false, detailMarkdown: nil)
        for prefix in prefixes(of: Self.recorded) {
            let current = try #require(progress(prefix), "prefix \(prefix.count) must yield a snapshot")
            #expect(final.hint.hasPrefix(current.hint), "the hint is a prefix of its final text")
            #expect(current.hint.hasPrefix(previous.hint), "the hint only grows")
            #expect(!previous.hintComplete || current.hintComplete, "the hint never reopens")
            if let detail = current.detailMarkdown {
                #expect(final.detailMarkdown?.hasPrefix(detail) == true)
            }
            previous = current
        }
    }

    @Test func anEscapeSplitAtTheEndIsHeldBackWhole() throws {
        let text = #"{"hint":"Say \"hi\" "# + "\\uD83D\\uDE00" + #" now"}"#
        func open(_ count: Int) throws -> String {
            try #require(progress(String(String.UnicodeScalarView(Array(text.unicodeScalars)[..<count])))).hint
        }
        let quote = try #require(text.range(of: #"\""#)).lowerBound.utf16Offset(in: text)
        #expect(try open(quote + 1) == "Say ", "a lone backslash shows nothing")
        #expect(try open(quote + 2) == "Say \"", "the closed escape shows its character")
        let surrogate = try #require(text.range(of: "\\uD83D")).lowerBound.utf16Offset(in: text)
        #expect(try open(surrogate + 6) == "Say \"hi\" ", "a high surrogate waits for its pair")
        #expect(try open(surrogate + 11) == "Say \"hi\" ", "a partial low surrogate still waits")
        #expect(try open(surrogate + 12) == "Say \"hi\" 😀")
        #expect(try #require(progress(text)).hint == "Say \"hi\" 😀 now")
    }

    @Test func detailMayArriveBeforeTheHint() throws {
        let text = #"{"detail":"Use a **map**.","hint":"Count first."}"#
        let midway = try #require(progress(String(text.prefix(#"{"detail":"Use a **m"#.count))))
        #expect(midway.detailMarkdown == "Use a **m")
        #expect(midway.hint.isEmpty && !midway.hintComplete)
        let final = try #require(progress(text))
        #expect(final.detailMarkdown == "Use a **map**.")
        #expect(final.hint == "Count first.")
        #expect(final.hintComplete)
    }

    @Test func aHintWithTheWrongTypeYieldsNothing() {
        for value in [#"["a","b"]"#, "null", "42", "{}"] {
            let text = #"{"hint":\#(value),"detail":null}"#
            for prefix in prefixes(of: text).dropFirst(#"{"hint":"#.count + 1) {
                #expect(progress(prefix) == nil, "prefix \(prefix.count) must yield nothing")
            }
        }
    }

    @Test func aNullDetailYieldsNoDetail() throws {
        let final = try #require(progress(#"{"hint":"One.","detail":null}"#))
        #expect(final.detailMarkdown == nil)
        #expect(final.hint == "One.")
        #expect(final.hintComplete)
    }

    @Test func aBlankHintCannotBeDeliveredEvenAfterItsQuoteCloses() throws {
        let text = #"{"hint":"  \n","detail":"Only detail."}"#
        let final = try #require(progress(text))
        #expect(final.hintComplete)
        #expect(final.hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: text) == nil)
    }

    @Test func unknownSiblingKeysAreSkipped() throws {
        let final = try #require(progress(#"{"tone":"warm","meta":{"n":[1,2,{"k":"]"}]},"hint":"A.","extra":true}"#))
        #expect(final.hint == "A.")
        #expect(final.hintComplete)
    }

    /// A delimiter where a value belongs is malformed; the scanner must stop, not spin.
    @Test func aDelimiterInValuePositionEndsTheScan() throws {
        for text in [#"{"meta":},"hint":"A."}"#, #"{"meta":],"hint":"A."}"#] {
            let snapshot = try #require(progress(text), "\(text) must yield a snapshot")
            #expect(!snapshot.hintComplete)
        }
        #expect(try #require(progress(#"{"hint":"A.""#)).hintComplete,
                "the hint completes at its quote, before any comma or object close")
    }

    @Test func nothingYetIsAnEmptySnapshot() throws {
        for prefix in ["", "{", #"{"hi"#, #"{"hint""#, #"{"hint":"#, #"{"hint":""#] {
            let snapshot = try #require(progress(prefix))
            #expect(!snapshot.hasText, "prefix \(prefix) shows nothing")
            #expect(!snapshot.hintComplete)
        }
    }
}
