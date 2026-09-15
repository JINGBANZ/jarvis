import Testing
@testable import JarvisCore

@Suite struct PrepMaterialChunkerCompatibilityTests {
    @Test(arguments: ["md", "txt", "pdf", "docx"])
    func everySupportedFormatCanSupplyEveryInterviewTopic(_ fileExtension: String) throws {
        // PDF/Word fixtures represent extracted text: format decoding precedes this shared index.
        let materials = [
            ("behavioral", "mentoring", "Mentoring: I coached an apprentice into an engineering role."),
            ("coding", "binary", "Binary search: halve the remaining sorted range each iteration."),
            ("system-design", "replication", "Replication: asynchronous copies trade freshness for availability."),
        ]
        let chunks = materials.flatMap { topic, _, text in
            PrepMaterialChunker.chunk(text: text, sourceDisplayName: "\(topic).\(fileExtension)")
        }
        let index = PrepMaterialIndex(chunks: chunks)
        for (topic, query, text) in materials {
            let result = try #require(index.search(query: query).first)
            #expect(result.sourceDisplayName == "\(topic).\(fileExtension)")
            #expect(result.text == text)
        }
    }

    @Test(arguments: ["notes.txt", "design.pdf", "resume.docx", "untitled"])
    func nonMarkdownSourcesKeepLiteralSymbolsInTheirParagraphs(_ name: String) {
        let text = "Context.\n\n# A literal heading-like line\n\n| input | output |\n| value | result |"
        let chunks = PrepMaterialChunker.chunk(text: text, sourceDisplayName: name)
        #expect(chunks.map(\.text) == [text])
        #expect(chunks.allSatisfy { $0.sourceDisplayName == name })
    }

    @Test(arguments: ["```", "~~~"])
    func fencedCodeKeepsBlankLinesCommentsAndPipes(_ fence: String) throws {
        let code = "\(fence)python\nvalue = 1\n\n# Preserve this comment\n\n| literal | pipe |\n| another | line |\n\(fence)"
        let chunks = PrepMaterialChunker.chunk(
            text: "## Coding\n\n\(code)\n\n## Design\n\nUse a queue.",
            sourceDisplayName: "notes.md", targetWordCount: 12)
        let result = try #require(chunks.first { $0.text.contains("value = 1") })
        #expect(result.text.contains(code))
        #expect(!result.text.contains("Use a queue."))
    }

    @Test func indentedHeadingDoesNotStartASection() {
        let text = "Example:\n\n    # comment\n    | literal | data |\n    | more | data |"
        let chunks = PrepMaterialChunker.chunk(text: text, sourceDisplayName: "coding.md")
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("    # comment\n    | literal | data |"))
    }

    @Test(arguments: ["    ", "\t"])
    func indentedTableSyntaxRemainsCode(_ indent: String) {
        let lines = ["| Key | Value |", "| --- | --- |", "| first | one value |", "| second | another value |"]
        let code = lines.map { indent + $0 }.joined(separator: "\n")
        let chunks = PrepMaterialChunker.chunk(
            text: code, sourceDisplayName: "coding.md", targetWordCount: 12)
        #expect(chunks.map(\.text) == [code])
    }

    @Test(arguments: ["# Empty", "# Empty\n\n## Still empty"])
    func trailingHeadingsDoNotCreateEvidence(_ headings: String) {
        #expect(PrepMaterialChunker.chunk(text: headings, sourceDisplayName: "notes.md").isEmpty)
        let evidence = "## Delivery\n\nWe shipped the release."
        let chunks = PrepMaterialChunker.chunk(
            text: evidence + "\n\n" + headings, sourceDisplayName: "notes.md")
        #expect(chunks.map(\.text) == [evidence])
        #expect(PrepMaterialIndex(chunks: chunks).search(query: "Empty").isEmpty)
    }

    @Test func headingImmediatelyBeforeTableKeepsFirstRows() {
        let headings = "# Storage\n## Latency"
        let header = "| Strategy | Benefit |\n|---|---|"
        let rows = ["| Cache | fast reads |", "| Replica | stale reads |"]
        let chunks = PrepMaterialChunker.chunk(
            text: headings + "\n" + header + "\n" + rows.joined(separator: "\n"),
            sourceDisplayName: "design.md", targetWordCount: 12)
        #expect(chunks.map(\.text) == [headings + "\n" + header + "\n" + rows[0], header + "\n" + rows[1]])
    }

    @Test func pipeLinesWithoutTableDelimiterRemainAParagraph() {
        let text = "| first literal line |\n| second literal line |"
        let chunks = PrepMaterialChunker.chunk(
            text: text, sourceDisplayName: "design.md", targetWordCount: 4)
        #expect(chunks.map(\.text) == [text])
    }

    @Test(arguments: ["::---", "---::", "::---::"])
    func malformedTableAlignmentRemainsOrdinaryText(_ delimiter: String) {
        let text = "| Key | Value |\n| \(delimiter) | --- |\n| first | a value |\n| second | another value |"
        let chunks = PrepMaterialChunker.chunk(
            text: text, sourceDisplayName: "notes.md", targetWordCount: 12)
        #expect(chunks.map(\.text) == [text])
    }

    @Test(arguments: ["-", "--", ":-", "-:", ":-:"])
    func shortTableDelimitersRepeatHeaders(_ delimiter: String) {
        let header = "| Key | Value |\n| \(delimiter) | - |"
        let rows = ["| first | a value |", "| second | another value |"]
        let chunks = PrepMaterialChunker.chunk(
            text: header + "\n" + rows.joined(separator: "\n"),
            sourceDisplayName: "notes.md", targetWordCount: 12)
        #expect(chunks.map(\.text) == rows.map { header + "\n" + $0 })
    }

    @Test(arguments: [8, 400])
    func consecutiveHeadingsStayWithFollowingEvidence(_ targetWordCount: Int) throws {
        let section = "# Mentoring\n\n## Apprentice\n\nI explained fundamentals and the apprentice became an engineer."
        let chunks = PrepMaterialChunker.chunk(
            text: section + "\n\n## Delivery\n\nWe shipped a release.",
            sourceDisplayName: "notes.md", targetWordCount: targetWordCount)
        let result = try #require(PrepMaterialIndex(chunks: chunks).search(query: "Mentoring").first)
        #expect(result.text == section)
        #expect(chunks.count == 2)
    }

    @Test func headingBeforeOversizedTableStaysWithFirstRows() throws {
        let heading = "# Storage\n\n## Latency"
        let header = "| Strategy | Benefit |\n|---|---|"
        let rows = ["| Cache | fast reads |", "| Replica | stale reads |"]
        let chunks = PrepMaterialChunker.chunk(
            text: heading + "\n\n" + header + "\n" + rows.joined(separator: "\n"),
            sourceDisplayName: "design.md", targetWordCount: 12)
        #expect(chunks.map(\.text) == [heading + "\n\n" + header + "\n" + rows[0], header + "\n" + rows[1]])
        let result = try #require(PrepMaterialIndex(chunks: chunks).search(query: "Latency").first)
        #expect(result.text.contains(rows[0]))
    }

    @Test func splitComparisonTablesKeepHeadersWithEveryRow() {
        let header = "| Strategy | Benefit | Risk |\n|---|---|---|"
        let rows = (1...8).map { "| Strategy\($0) | fast reads | stale results |" }
        let chunks = PrepMaterialChunker.chunk(
            text: header + "\n" + rows.joined(separator: "\n"),
            sourceDisplayName: "system-design.md", targetWordCount: 30)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.text.hasPrefix(header + "\n"))
        }
        for row in rows {
            #expect(chunks.filter { $0.text.components(separatedBy: "\n").contains(row) }.count == 1)
        }
    }

    @Test func shortComparisonKeepsItsContextAndCaveat() throws {
        let text = """
        ## Storage options

        These measurements use a synthetic workload.

        | Strategy | Latency |
        |---|---|
        | Cache | Lower |

        **Caveat:** Not measured in production.
        """
        let chunks = PrepMaterialChunker.chunk(text: text, sourceDisplayName: "design.md")
        let result = try #require(PrepMaterialIndex(chunks: chunks).search(query: "Cache").first)
        #expect(result.text == text)
    }

    @Test(arguments: ["notes.txt", "notes.md", "export.pdf", "export.docx"])
    func unicodeListsAndExtractedParagraphsRemainSearchable(_ name: String) {
        let text = "项目：缓存设计。\r\n\r\n- Reduce latency\r\n- Preserve correctness\r\n\r\nRésultat : amélioration."
        let chunks = PrepMaterialChunker.chunk(text: text, sourceDisplayName: name)
        #expect(chunks.map(\.text) == ["项目：缓存设计。\n\n- Reduce latency\n- Preserve correctness\n\nRésultat : amélioration."])
        let results = PrepMaterialIndex(chunks: chunks).search(query: "latency")
        #expect(results.first?.text.contains("Preserve correctness") == true)
    }
}
