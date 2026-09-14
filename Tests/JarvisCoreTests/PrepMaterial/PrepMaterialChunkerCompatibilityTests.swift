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

    @Test func indentedCodeDoesNotBecomeAHeadingOrTable() {
        let text = "Example:\n\n    # comment\n    | literal | data |\n    | more | data |"
        let chunks = PrepMaterialChunker.chunk(text: text, sourceDisplayName: "coding.md")
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("    # comment\n    | literal | data |"))
    }

    @Test func pipeLinesWithoutTableDelimiterRemainAParagraph() {
        let text = "| first literal line |\n| second literal line |"
        let chunks = PrepMaterialChunker.chunk(
            text: text, sourceDisplayName: "design.md", targetWordCount: 4)
        #expect(chunks.map(\.text) == [text])
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
