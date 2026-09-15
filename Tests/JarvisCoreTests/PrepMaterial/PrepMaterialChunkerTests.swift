import Testing
@testable import JarvisCore

@Suite struct PrepMaterialChunkerTests {
    @Test func emptyTextProducesNoChunks() {
        #expect(PrepMaterialChunker.chunk(text: "", sourceDisplayName: "notes.md").isEmpty)
        #expect(PrepMaterialChunker.chunk(text: "   \n\n  ", sourceDisplayName: "notes.md").isEmpty)
    }

    @Test func shortParagraphsMergeIntoOneChunk() {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let chunks = PrepMaterialChunker.chunk(
            text: text, sourceDisplayName: "notes.md", targetWordCount: 400)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == text)
        #expect(chunks[0].sourceDisplayName == "notes.md")
    }

    @Test func exceedingTargetWordCountStartsANewChunk() {
        let first = Array(repeating: "word", count: 10).joined(separator: " ")
        let second = Array(repeating: "word", count: 10).joined(separator: " ")
        let text = "\(first)\n\n\(second)"
        let chunks = PrepMaterialChunker.chunk(
            text: text, sourceDisplayName: "notes.md", targetWordCount: 15)
        #expect(chunks.count == 2)
        #expect(chunks[0].text == first)
        #expect(chunks[1].text == second)
    }

    @Test func oversizedSingleParagraphBecomesItsOwnChunk() {
        let long = Array(repeating: "word", count: 1000).joined(separator: " ")
        let chunks = PrepMaterialChunker.chunk(
            text: long, sourceDisplayName: "notes.md", targetWordCount: 400)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == long)
    }

    @Test func storyHeadingKeepsItsBoundaryOutOfThePreviousStory() throws {
        let text = """
        ### First story

        Some unrelated background fills this earlier story with extra words.

        ### Dependency mistake
        I shipped a smaller milestone after discovering a dependency.

        **Boundary:** No missed commitment is established.

        ### Mentoring

        A different experience.
        """
        let chunks = PrepMaterialChunker.chunk(
            text: text, sourceDisplayName: "notes.md", targetWordCount: 30)
        let index = PrepMaterialIndex(chunks: chunks)
        let result = try #require(index.search(query: "dependency mistake").first)
        #expect(result.text.contains("I shipped a smaller milestone"))
        #expect(result.text.contains("No missed commitment is established."))
        #expect(!result.text.contains("First story"))
        #expect(!result.text.contains("Mentoring"))
    }

    @Test func longTableSplitsBetweenRowsWithoutLosingQuestions() {
        let rows = (1...20).map { "| \($0) | Question number \($0) | Partial |" }
        let table = (["| ID | Question | Status |", "|---|---|---|"] + rows).joined(separator: "\n")
        let chunks = PrepMaterialChunker.chunk(
            text: "## Question map\n\n\(table)", sourceDisplayName: "notes.md", targetWordCount: 40)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.split(whereSeparator: \.isWhitespace).count <= 40 })
        for row in rows {
            #expect(chunks.filter { $0.text.components(separatedBy: "\n").contains(row) }.count == 1)
        }
    }
}
