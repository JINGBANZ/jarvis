import Testing
@testable import JarvisCore

/// A detail read while the model is still writing it.
@Suite struct ReplyDetailPartialTests {
    private static let document = """
        Sketch the read path, then start here.

        ```mermaid
        flowchart LR
        client[Client] --> api[Search API]
        api[Search API] --> cache[Cache]
        ```

        ```python
        last_seen = {}
        left = 0
        ```

        Move `left` forward only.
        """

    @Test(arguments: [
        "Check the empty list first.\n\nThen index into it.",
        "Try this.\n\n```python\na = 1\n```",
        "```python\na = 1\n```\nThen scan.",
        "Try this.\n\n```python\na = 1\n",
        document,
    ])
    func textWithNoUnfinishedFenceLineReadsAsDelivered(_ markdown: String) {
        #expect(ReplyDetail(partialMarkdown: markdown) == ReplyDetail(markdown: markdown))
    }

    @Test func anUnfinishedLineInsideAnOpenCodeFenceWaitsForItsNewline() {
        let waiting = ReplyDetail(partialMarkdown: "Try this.\n\n```python\na = 1\nb = ")
        #expect(waiting?.code?.code == "a = 1")
        #expect(waiting?.deliveredMarkdown.contains("Try this.") == true)
        let closed = ReplyDetail(partialMarkdown: "Try this.\n\n```python\na = 1\nb = 2\n")
        #expect(closed?.code?.code == "a = 1\nb = 2")
    }

    @Test func anOpenMermaidFenceKeepsTheDiagramOfItsCompleteLines() {
        let partial = ReplyDetail(partialMarkdown:
            "```mermaid\nflowchart LR\nclient[Client] --> api[API]\napi[API] --> cache[Cac")
        #expect(partial?.diagram?.nodes.map(\.label) == ["Client", "API"])
        #expect(partial?.dropped.isEmpty == true)
        let complete = ReplyDetail(partialMarkdown:
            "```mermaid\nflowchart LR\nclient[Client] --> api[API]\napi[API] --> cache[Cache]\n")
        #expect(complete?.diagram?.nodes.map(\.label) == ["Client", "API", "Cache"])
    }

    @Test func aHalfWrittenOpenerShowsNothingOfTheFence() {
        let afterProse = ReplyDetail(partialMarkdown: "Here.\n\n```pyth")
        #expect(afterProse?.code == nil)
        #expect(afterProse?.deliveredMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) == "Here.")
        #expect(ReplyDetail(partialMarkdown: "```pyth") == nil)
        #expect(ReplyDetail(partialMarkdown: "```python\n")?.hasContent == false, "an opener with no body yet shows nothing")
    }

    @Test func aClosedFenceFollowedByUnfinishedProseReadsWhole() {
        let detail = ReplyDetail(partialMarkdown: "```python\na = 1\n```\nThen sca")
        #expect(detail?.code?.code == "a = 1")
        #expect(detail?.deliveredMarkdown.hasSuffix("Then sca") == true)
    }

    @Test func fencesReportWhetherTheirCloserArrived() {
        #expect(ReplyDetail.fences(in: "```py\na\n```").map(\.isClosed) == [true])
        #expect(ReplyDetail.fences(in: "```py\na\n```\n~~~\nb").map(\.isClosed) == [true, false])
    }

    /// No snapshot shows a block, or part of one, that the delivered detail does not hold.
    @Test func everyPrefixShowsOnlyWhatTheDeliveredDetailHolds() throws {
        let document = Self.document
        let delivered = try #require(ReplyDetail(markdown: document))
        let finalCode = try #require(delivered.code)
        let finalDiagram = try #require(delivered.diagram)
        var shownDiagram = false
        var shownCode = false
        for end in document.indices.dropFirst() {
            let snapshot = ReplyDetail(partialMarkdown: String(document[..<end]))
            if let code = snapshot?.code {
                shownCode = true
                #expect(code.language == finalCode.language)
                #expect(finalCode.code.hasPrefix(code.code))
            }
            if let diagram = snapshot?.diagram {
                shownDiagram = true
                #expect(diagram.direction == finalDiagram.direction)
                #expect(diagram.nodes.allSatisfy(finalDiagram.nodes.contains))
                #expect(diagram.edges.allSatisfy(finalDiagram.edges.contains))
            }
        }
        #expect(shownCode && shownDiagram, "both blocks appear before the document ends")
        #expect(ReplyDetail(partialMarkdown: document) == delivered)
    }
}
