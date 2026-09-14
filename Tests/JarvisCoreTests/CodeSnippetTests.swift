import Testing
@testable import JarvisCore

@Suite struct CodeSnippetTests {
    @Test func preservesExpandedComponentAndLateCorrectionHighlights() throws {
        let code = (1...24).map { "    values.append(\($0))" }.joined(separator: "\n")
        let snippet = try #require(CodeSnippet(language: "python", placement: "Inside the current block",
            code: code, highlightedLines: [13, 24]))
        #expect(snippet.code == code)
        #expect(snippet.highlightedLines == [13, 24])
    }

    @Test(arguments: ["\r", "\u{2028}"])
    func rejectsUnsupportedNewlinesThatWouldBypassLineLimit(_ separator: String) {
        let code = Array(repeating: "return value", count: 13).joined(separator: separator)
        #expect(CodeSnippet(language: "swift", placement: "Inside solve", code: code) == nil)
    }

    @Test func trimsLeadingLinesWithoutMovingCorrectionHighlights() throws {
        let snippet = try #require(CodeSnippet(language: "python", placement: "Loop",
            code: "\n\nif ch in seen:\n    left = seen[ch] + 1\n", highlightedLines: [Int.min, 1, 3, 4, Int.max]))
        #expect(snippet.highlightedLines == [1, 2])
    }

    @Test func rejectsTooManyHighlightIndicesBeforeNormalization() {
        #expect(CodeSnippet(language: "swift", placement: "Start", code: "let x = 1",
                            highlightedLines: Array(repeating: 1, count: 13)) == nil)
        #expect(CodeSnippet(language: "swift", placement: "Start", code: "let x = 1",
                            highlightedLines: Array(repeating: 1, count: 12))?.highlightedLines == [1])
    }

    @Test func preservesIndentationAndRejectsPartialOversizeCode() throws {
        let snippet = try #require(CodeSnippet(language: " swift ", placement: " Inside solve ",
            code: "\r\n  let value = 1\r\n    return value\r\n", highlightedLines: [-1, 1, 1, 3]))
        #expect(snippet.code == "  let value = 1\n    return value")
        #expect(snippet.highlightedLines == [2])
        #expect(snippet.language == "swift")
        #expect(snippet.placement == "Inside solve")
        #expect(CodeSnippet(language: "", placement: "x", code: String(repeating: "x\n", count: 25)) == nil)
        #expect(CodeSnippet(language: "", placement: "x", code: String(repeating: "x", count: 2401)) == nil)
        #expect(CodeSnippet(language: "", placement: " ", code: "x") == nil)
        #expect(CodeSnippet(language: "", placement: "x", code: " \n ") == nil)
    }
}
