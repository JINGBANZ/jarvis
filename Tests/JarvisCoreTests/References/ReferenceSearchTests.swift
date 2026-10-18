import Foundation
import Testing
@testable import JarvisCore

struct ReferenceSearchTests {
    @Test func identifiersRemainDistinctAndInputIsLiteral() throws {
        let plus = try #require(ReferenceSearchTokenizer.matchExpression("C++"))
        let hash = try #require(ReferenceSearchTokenizer.matchExpression("C#"))
        #expect(plus != hash)
        #expect(ReferenceSearchTokenizer.matchExpression("账单-42") != ReferenceSearchTokenizer.matchExpression("账单_42"))
        #expect(ReferenceSearchTokenizer.matchExpression("账单_42") != ReferenceSearchTokenizer.matchExpression("账单 42"))
        let hostile = try #require(ReferenceSearchTokenizer.matchExpression("x\" OR * NOT (y)"))
        #expect(!hostile.contains("*"))
        #expect(!hostile.contains("NOT"))
        #expect(ReferenceSearchTokenizer.matchExpression("😀") == nil)
        #expect(ReferenceSearchTokenizer.encoded("C++") != ReferenceSearchTokenizer.encoded("C#"))
    }

    @Test func multilingualTermsCarryOriginalScalarOffsets() {
        let source = "😀e\u{301} 支付失败 C++ 账单-42"
        let terms = ReferenceSearchTokenizer.terms(source)
        #expect(terms.contains { $0.value == "支付" })
        #expect(terms.contains { $0.value == "失败" })
        #expect(terms.contains { $0.value == "账单-42" })
        for term in terms {
            let scalars = source.unicodeScalars
            let start = scalars.index(scalars.startIndex, offsetBy: term.offset)
            let end = scalars.index(scalars.startIndex, offsetBy: term.endOffset)
            #expect(String(scalars[start..<end]).precomposedStringWithCanonicalMapping.lowercased() == term.value)
        }
    }

    @Test func identifierTopicsRankWithoutChangingExcerptAnchors() throws {
        #expect(ReferenceSearchTokenizer.queryTerms("client-side cancellation") == ["client-side"])
        #expect(ReferenceSearchTokenizer.queryTerms("cache-key parser.v2 cancellation") == ["cache-key", "parser.v2"])
        let mixed = try #require(ReferenceSearchTokenizer.matchExpression("client-side cancellation"))
        #expect(mixed.contains("\"" + ReferenceSearchTokenizer.encoded("cancellation") + "\""))
        #expect(!mixed.contains("\"" + ReferenceSearchTokenizer.encoded("client") + "\""))
        #expect(!mixed.contains("\"" + ReferenceSearchTokenizer.encoded("side") + "\""))
        let chinese = try #require(ReferenceSearchTokenizer.matchExpression("账单-42 失败退款"))
        #expect(chinese.contains("\"" + ReferenceSearchTokenizer.encoded("失败") + "\""))
        #expect(!chinese.contains("\"" + ReferenceSearchTokenizer.encoded("失") + "\""))
        #expect(ReferenceSearchTokenizer.queryTerms("账单-42 失败退款") == ["账单-42"])
    }

    @Test func sentencePunctuationAndIdentifierRangesStayConsistent() throws {
        #expect(ReferenceSearchTokenizer.matchExpression("How does retry backoff work.") == ReferenceSearchTokenizer.matchExpression("How does retry backoff work"))
        for (punctuated, word) in [("docs/", "docs"), ("long-", "long"), ("word_", "word")] {
            #expect(ReferenceSearchTokenizer.matchExpression(punctuated) == ReferenceSearchTokenizer.matchExpression(word))
        }
        #expect(ReferenceSearchTokenizer.queryTerms(".NET .env") == [".net", ".env"])
        #expect(ReferenceSearchTokenizer.queryTerms("../foo") == ["../foo"])
        #expect(ReferenceSearchTokenizer.queryTerms("/foo") == ["/foo"])
        #expect(ReferenceSearchTokenizer.queryTerms("账单-42") == ["账单-42"])
        #expect(ReferenceSearchTokenizer.queryTerms("账单_42") == ["账单_42"])
        for punctuation in [".", "...", "/", "-", "_", "+", "#"] {
            #expect(ReferenceSearchTokenizer.matchExpression(punctuation) == nil)
        }
        let source = "retry... C++. 账单-42. 账单_42..."
        let terms = ReferenceSearchTokenizer.terms(source)
        for (value, range) in [("retry", 0..<5), ("c++", 9..<12), ("账单-42", 14..<19), ("账单_42", 21..<26)] {
            #expect(terms.contains { $0.value == value && $0.offset == range.lowerBound && $0.endOffset == range.upperBound })
        }
        #expect(try #require(ReferenceSearchTokenizer.matchExpression("C++.")) == ReferenceSearchTokenizer.matchExpression("C++"))
    }

    @Test func passageRangesPreserveCRLFCodeTablesAndUnicode() {
        let source = "# First\r\n\r\n😀e\u{301} content\r\n\r\n```swift\r\n# code\r\n\r\nlet answer = 42\r\n```\r\n\r\n# Second\r\n| key | value |\r\n| --- | --- |\r\n| x | y |\r\n"
        let passages = PrepMaterialChunker.passages(text: source, markdown: true, targetScalars: 80)
        #expect(passages.map { String(source[$0.range]) }.joined() == source)
        #expect(passages.contains { source[$0.range].contains("```swift\r\n# code\r\n\r\nlet answer = 42\r\n```") })
        #expect(passages.last?.section == "# Second")
        var offset = 0
        for passage in passages {
            #expect(passage.offset == offset)
            offset += source[passage.range].unicodeScalars.count
        }
    }

    @Test(arguments: ["# Empty\n\n## Still empty\n", "# Empty " + String(repeating: "heading ", count: 3_000) + "\n"])
    func headingOnlyPassagesAreOmitted(_ headings: String) {
        #expect(PrepMaterialChunker.passages(text: headings, markdown: true).isEmpty)
        let evidence = "# Delivery\r\n\r\nWe shipped.\r\n\r\n"
        let text = evidence + headings
        let passages = PrepMaterialChunker.passages(text: text, markdown: true)
        #expect(passages.map { String(text[$0.range]) }.joined() == evidence)
        #expect(passages.first?.offset == 0)
        #expect(PrepMaterialChunker.passages(text: headings, markdown: false).map { String(headings[$0.range]) }.joined() == headings)
    }

    @Test func headingGroupsAndLongHeadingBodiesKeepOriginalRanges() {
        let grouped = "# Context\r\n\r\n## Details\r\n\r\nactual evidence\r\n"
        let small = PrepMaterialChunker.passages(text: grouped, markdown: true, targetScalars: 8)
        #expect(small.count == 1)
        #expect(small.map { String(grouped[$0.range]) }.joined() == grouped)
        let text = "# " + String(repeating: "heading ", count: 3_000) + "\nactual evidence\n"
        let passages = PrepMaterialChunker.passages(text: text, markdown: true)
        #expect(passages.count == 1)
        #expect(passages.allSatisfy { text[$0.range].unicodeScalars.count <= 16_000 })
        #expect(passages.last.map { text[$0.range].contains("actual evidence") } == true)
        for passage in passages {
            #expect(passage.offset == text[..<passage.range.lowerBound].unicodeScalars.count)
        }
    }

    @Test func plainTextWhitespaceKeepsOriginalRanges() {
        let text = String(repeating: " \t", count: 9_000) + "\r\n" + String(repeating: " \t\r\n", count: 4_001)
        let passages = PrepMaterialChunker.passages(text: text, markdown: false)
        #expect(passages.map { String(text[$0.range]) }.joined() == text)
        #expect(passages.allSatisfy { text[$0.range].unicodeScalars.count <= 16_000 })
        for passage in passages {
            #expect(passage.offset == text[..<passage.range.lowerBound].unicodeScalars.count)
        }
    }

    @Test func hostileLongBlocksHaveBoundedPassages() {
        let text = "```\n" + String(repeating: "😀e\u{301}", count: 20_000) + "\n```"
        let passages = PrepMaterialChunker.passages(text: text, markdown: true)
        #expect(passages.allSatisfy { text[$0.range].unicodeScalars.count <= 16_000 })
        #expect(passages.map { String(text[$0.range]) }.joined() == text)
    }

    @Test func headingAfterLongParagraphDoesNotRelabelItsTail() {
        let text = "# Original\n" + String(repeating: "x", count: 40_000) + "\n# Next\nnext section"
        let passages = PrepMaterialChunker.passages(text: text, markdown: true)
        #expect(passages.map { String(text[$0.range]) }.joined() == text)
        #expect(passages.filter { text[$0.range].contains("xxxx") }.allSatisfy { $0.section == "# Original" })
        #expect(passages.last?.section == "# Next")
    }

    @Test func longFenceSuffixAndHeadingClassificationRemainExact() {
        let text = "# Original\n```swift\n```" + String(repeating: " ", count: 32_000) + "not a closing fence\n# Still code\n```\n# Final\nlast\n"
        let passages = PrepMaterialChunker.passages(text: text, markdown: true)
        #expect(passages.map { String(text[$0.range]) }.joined() == text)
        #expect(passages.allSatisfy { text[$0.range].unicodeScalars.count <= 16_000 })
        #expect(passages.filter { text[$0.range].contains("# Still code") }.allSatisfy { $0.section == "# Original" })
        #expect(passages.last?.section == "# Final")
    }

    @Test func coverageAndTruncationRoundTripIndependently() throws {
        let result = ReferenceSearchResult(hits: [], complete: true, truncated: true,
            coverage: ReferenceSearchCoverage(eligibleDocuments: 10, searchedDocuments: 10, omissions: [:], metadataGeneration: 7, indexVersion: "fixture"))
        #expect(try JSONDecoder().decode(ReferenceSearchResult.self, from: JSONEncoder().encode(result)) == result)
    }
}
