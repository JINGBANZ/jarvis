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
}
