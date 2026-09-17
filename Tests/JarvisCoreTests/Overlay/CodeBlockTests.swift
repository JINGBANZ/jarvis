import Testing
@testable import JarvisCore

@Suite struct CodeBlockTests {
    @Test func preservesAFullTwentyFourLineComponent() throws {
        let code = (1...24).map { "    values.append(\($0))" }.joined(separator: "\n")
        let block = try #require(CodeBlock(language: "python", code: code))
        #expect(block.code == code)
        #expect(!block.isDiff)
    }

    @Test(arguments: ["\r", "\u{2028}"])
    func rejectsUnsupportedNewlinesThatWouldBypassLineLimit(_ separator: String) {
        let code = Array(repeating: "return value", count: 13).joined(separator: separator)
        #expect(CodeBlock(language: "swift", code: code) == nil)
    }

    @Test func preservesIndentationAndRejectsPartialOversizeCode() throws {
        let block = try #require(CodeBlock(language: " Swift ", code: "\r\n  let value = 1\r\n    return value\r\n"))
        #expect(block.code == "  let value = 1\n    return value")
        #expect(block.language == "swift")
        #expect(CodeBlock(language: "", code: String(repeating: "x\n", count: 25)) == nil)
        #expect(CodeBlock(language: "", code: String(repeating: "x", count: 2401)) == nil)
        #expect(CodeBlock(language: "", code: " \n ") == nil)
    }

    @Test func anUnnamedLanguageBecomesText() throws {
        #expect(try #require(CodeBlock(language: "", code: "x = 1")).language == "text")
        #expect(CodeBlock(language: String(repeating: "x", count: 41), code: "x = 1") == nil)
    }

    @Test func aDiffBlockIsRecognized() throws {
        let block = try #require(CodeBlock(language: "diff", code: "-  if ch in seen:\n+  if ch in seen and seen[ch] >= left:"))
        #expect(block.isDiff)
        #expect(!(try #require(CodeBlock(language: "python", code: "x = 1")).isDiff))
    }
}
