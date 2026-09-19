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
        "Try this.\n\n```python\na = 1\nb = ",
        "```mermaid\nflowchart LR\nclient[Client] --> api[API]\n```\nThen sca",
        document,
    ])
    func textThatDoesNotEndInsideADiagramReadsAsDelivered(_ markdown: String) {
        #expect(ReplyDetail(partialMarkdown: markdown) == ReplyDetail(markdown: markdown))
    }

    @Test func aCodeBlockGrowsWithItsHalfWrittenLineVisible() {
        let half = ReplyDetail(partialMarkdown: "Try this.\n\n```python\na = 1\nb = ")
        #expect(half?.code?.code == "a = 1\nb = ")
        #expect(half?.deliveredMarkdown.hasPrefix("Try this.") == true)
        let whole = ReplyDetail(partialMarkdown: "Try this.\n\n```python\na = 1\nb = 2")
        #expect(whole?.code?.code == "a = 1\nb = 2")
    }

    @Test func aHalfWrittenOpenerShowsNothingOfTheFence() {
        let afterProse = ReplyDetail(partialMarkdown: "Here.\n\n```pyth")
        #expect(afterProse?.code == nil)
        #expect(afterProse?.deliveredMarkdown == "Here.")
        #expect(ReplyDetail(partialMarkdown: "```pyth")?.hasContent == false)
    }

    @Test func anOpenDiagramContributesNothingUntilItsFenceCloses() {
        let open = ReplyDetail(partialMarkdown:
            "Sketch it.\n\n```mermaid\nflowchart LR\nclient[Client] --> api[API]\napi --> cache[Cac")
        #expect(open?.diagram == nil)
        #expect(open?.deliveredMarkdown == "Sketch it.")
        #expect(open?.dropped.isEmpty == true)
        let closed = ReplyDetail(partialMarkdown:
            "Sketch it.\n\n```mermaid\nflowchart LR\nclient[Client] --> api[API]\napi --> cache[Cache]\n```")
        #expect(closed?.diagram?.nodes.map(\.label) == ["Client", "API", "Cache"])
        #expect(closed?.deliveredMarkdown.hasPrefix("Sketch it.") == true)
    }

    @Test func aDetailThatIsOnlyAnOpenDiagramHasNoContentYet() {
        let detail = ReplyDetail(partialMarkdown: "```mermaid\nflowchart LR\nclient[Client] --> api[API]")
        #expect(detail != nil, "the box files it, so the placeholder has a detail to sit in")
        #expect(detail?.hasContent == false)
        #expect(detail?.deliveredMarkdown == "")
        #expect(ReplyDetail(partialMarkdown: " \n") == nil)
    }

    @Test func endsInsideADiagramFollowsTheLastFence() {
        #expect(ReplyDetail.endsInsideADiagram("```mermaid\nflowchart LR\nclient --> api"))
        #expect(ReplyDetail.endsInsideADiagram("Sketch it.\n\n```mermaid"))
        #expect(!ReplyDetail.endsInsideADiagram("```mermaid\nflowchart LR\nclient --> api\n```"))
        #expect(!ReplyDetail.endsInsideADiagram("```mermaid\nflowchart LR\nclient --> api\n```\n```python\nx = "))
        #expect(!ReplyDetail.endsInsideADiagram("```python\nx = "))
        #expect(!ReplyDetail.endsInsideADiagram("Sketch it."))
    }

    @Test func fencesReportWhetherTheirCloserArrived() {
        #expect(ReplyDetail.fences(in: "```py\na\n```").map(\.isClosed) == [true])
        #expect(ReplyDetail.fences(in: "```py\na\n```\n~~~\nb").map(\.isClosed) == [true, false])
    }

    /// No snapshot shows a block, or part of one, that the delivered detail does not hold: code
    /// grows as a prefix of the final code, except while its closer is being written, and a
    /// diagram appears only whole.
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
                let closerInProgress = ["`", "``"].contains { code.code == finalCode.code + "\n" + $0 }
                #expect(finalCode.code.hasPrefix(code.code) || closerInProgress)
            }
            if let diagram = snapshot?.diagram {
                shownDiagram = true
                #expect(diagram == finalDiagram)
            }
        }
        #expect(shownCode && shownDiagram, "both blocks appear before the document ends")
        #expect(ReplyDetail(partialMarkdown: document) == delivered)
    }
}
