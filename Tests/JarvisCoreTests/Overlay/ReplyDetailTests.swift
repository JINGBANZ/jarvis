import Foundation
import Testing
@testable import JarvisCore

@Suite struct ReplyDetailTests {
    private func detail(_ markdown: String) -> ReplyDetail {
        ReplyDetail(markdown: markdown)!
    }

    private func proseSegments(_ detail: ReplyDetail) -> [AttributedString] {
        detail.segments.compactMap { segment -> AttributedString? in
            if case .prose(let text) = segment { text } else { nil }
        }
    }

    private func prose(_ detail: ReplyDetail) -> String {
        proseSegments(detail).map { String($0.characters) }.joined(separator: "\n")
    }

    private func outline(_ detail: ReplyDetail) -> [String] {
        detail.segments.map {
            switch $0 {
            case .prose(let text): "prose: \(String(text.characters))"
            case .code(let block): "code: \(block.code)"
            case .diagram(let diagram): "diagram: \(diagram.nodes.map(\.label).joined(separator: ", "))"
            }
        }
    }

    @Test func aSentenceAfterACodeBlockStaysBelowIt() {
        let d = detail("""
            First, track the last index.

            ```python
            last_seen = {}
            ```

            Then handle the empty string.
            """)
        #expect(outline(d) == ["prose: First, track the last index.",
                               "code: last_seen = {}",
                               "prose: Then handle the empty string."])
    }

    @Test func aNoteAfterADiagramStaysBelowIt() {
        let d = detail("""
            ```mermaid
            flowchart LR
            client[Client] --> api[Search API]
            ```

            The API owns the cache.

            ```python
            total = 0
            ```
            """)
        #expect(outline(d) == ["diagram: Client, Search API",
                               "prose: The API owns the cache.",
                               "code: total = 0"])
    }

    @Test func aBlankLineBetweenTwoBlocksIsNotAProseSegment() {
        let d = detail("```mermaid\nflowchart LR\na[Client] --> b[API]\n```\n\n   \n```python\ntotal = 0\n```\n")
        #expect(outline(d) == ["diagram: Client, API", "code: total = 0"])
    }

    @Test func aDroppedFenceDoesNotSplitTheProseAroundIt() {
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let d = detail("Before it.\n\n```python\n\(body)\n```\n\nAfter it.")
        #expect(d.segments.count == 1)
        #expect(prose(d).contains("Before it."))
        #expect(prose(d).contains("After it."))
        #expect(d.dropped.count == 1)
    }

    @Test func aLaterFenceOfAShownKindRendersInlineWhereItWasWritten() {
        let d = detail("```python\na = 1\n```\n\nOr shorter:\n\n```python\nb = 2\n```")
        #expect(d.segments.count == 2)
        #expect(outline(d).first == "code: a = 1")
        #expect(prose(d).contains("Or shorter:"))
        #expect(prose(d).contains("b = 2"))
    }

    @Test func plainTextIsProseAndIsReplayedAsSent() {
        let d = detail("Check the empty list first.\n\nThen index into it.")
        #expect(prose(d).contains("Check the empty list first."))
        #expect(d.code == nil)
        #expect(d.diagram == nil)
        #expect(d.dropped.isEmpty)
        #expect(d.deliveredMarkdown == "Check the empty list first.\n\nThen index into it.")
    }

    @Test func blankMarkdownIsNoDetailAtAll() {
        #expect(ReplyDetail(markdown: "") == nil)
        #expect(ReplyDetail(markdown: "   \n\t\n ") == nil)
    }

    @Test func theFirstMermaidFenceThatParsesBecomesTheDiagramAndLeavesTheProse() {
        let d = detail("""
            A first sketch of the read path.

            ```mermaid
            flowchart LR
            client[Client] --> api[Search API]
            ```
            """)
        #expect(d.diagram?.nodes.map(\.label) == ["Client", "Search API"])
        #expect(!prose(d).contains("flowchart LR"))
        #expect(prose(d).contains("A first sketch of the read path."))
        #expect(d.dropped.isEmpty)
        #expect(d.deliveredMarkdown.contains("```mermaid"))
    }

    @Test func aMermaidFenceThatDoesNotParseIsDroppedFromBothTheBoxAndTheReplay() {
        let d = detail("""
            Writes flow through a queue.

            ```mermaid
            sequenceDiagram
            A->>B: write
            ```
            """)
        #expect(d.diagram == nil)
        #expect(!prose(d).contains("sequenceDiagram"))
        #expect(prose(d).contains("Writes flow through a queue."))
        #expect(!d.deliveredMarkdown.contains("sequenceDiagram"))
        #expect(d.dropped.count == 1)
        #expect(d.dropped[0].contains("diagram"))
    }

    @Test func theFirstOtherFenceWithinBoundsBecomesTheCodeBlock() {
        let d = detail("""
            Put these above the loop.

            ```python
            last_seen = {}
            left = 0
            ```
            """)
        #expect(d.code?.language == "python")
        #expect(d.code?.code == "last_seen = {}\nleft = 0")
        #expect(!prose(d).contains("last_seen = {}"))
        #expect(d.dropped.isEmpty)
        #expect(d.deliveredMarkdown.contains("```python"))
    }

    @Test func anOversizedFenceIsDroppedAndReported() {
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let d = detail("Too long to show.\n\n```python\n\(body)\n```")
        #expect(d.code == nil)
        #expect(!d.deliveredMarkdown.contains("line 30"))
        #expect(d.dropped.count == 1)
        #expect(d.dropped[0].contains("24 lines"))
        #expect(prose(d).contains("Too long to show."))
    }

    @Test func aFenceWithNoLanguageRendersAsText() {
        let d = detail("Here it is.\n\n```\nfoo = 1\n```")
        #expect(d.code?.language == "text")
        #expect(d.code?.code == "foo = 1")
        #expect(d.dropped.isEmpty)
    }

    @Test func aSecondFenceOfARoutedKindStaysInTheProse() {
        let d = detail("""
            One.

            ```python
            a = 1
            ```

            Two.

            ```python
            b = 2
            ```
            """)
        #expect(d.code?.code == "a = 1")
        #expect(prose(d).contains("b = 2"))
        #expect(!prose(d).contains("a = 1"))
        #expect(d.deliveredMarkdown.contains("a = 1"))
        #expect(d.deliveredMarkdown.contains("b = 2"))
    }

    /// CommonMark closes an unclosed fence at the end of the document, so the block still routes.
    @Test func anUnclosedFenceRunsToTheEnd() {
        let d = detail("Try this.\n\n```python\na = 1\nb = 2")
        #expect(d.code?.code == "a = 1\nb = 2")
        #expect(d.dropped.isEmpty)
        #expect(d.deliveredMarkdown == "Try this.\n\n```python\na = 1\nb = 2")
    }

    @Test func linksAndImagesBecomePlainText() {
        let d = detail("See [the docs](https://example.com) and ![a chart](https://example.com/c.png).")
        let text = prose(d)
        #expect(text.contains("the docs"))
        #expect(text.contains("a chart"))
        #expect(!text.contains("example.com"))
        for run in proseSegments(d).flatMap(\.runs) {
            #expect(run.link == nil)
        }
    }

    @Test func aDiagramThatParsesAfterOneThatDoesNotStillRenders() {
        let d = detail("""
            ```mermaid
            sequenceDiagram
            A->>B: write
            ```

            ```mermaid
            flowchart LR
            a[Client] --> b[API]
            ```
            """)
        #expect(d.diagram?.nodes.map(\.label) == ["Client", "API"])
        #expect(d.dropped.count == 1)
        #expect(!d.deliveredMarkdown.contains("sequenceDiagram"))
        #expect(d.deliveredMarkdown.contains("flowchart LR"))
        #expect(!prose(d).contains("flowchart LR"))
    }

    @Test func aCodeBlockWithinBoundsAfterAnOversizedOneStillRenders() {
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let d = detail("```python\n\(body)\n```\n\n```python\ntotal = 0\n```")
        #expect(d.code?.code == "total = 0")
        #expect(d.dropped.count == 1)
        #expect(!d.deliveredMarkdown.contains("line 30"))
        #expect(d.deliveredMarkdown.contains("total = 0"))
    }

    @Test func aFenceAfterTheShownOneOfItsKindStaysInTheProse() {
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let d = detail("```python\ntotal = 0\n```\n\n```python\n\(body)\n```")
        #expect(d.code?.code == "total = 0")
        #expect(d.dropped.isEmpty)
        #expect(prose(d).contains("line 30"))
    }

    @Test func fencesFollowCommonMarkDelimiters() {
        let tildes = ReplyDetail.fences(in: "~~~js\nlet a = 1\n~~~")
        #expect(tildes.map(\.language) == ["js"])
        #expect(tildes.first?.body == "let a = 1")

        let longer = ReplyDetail.fences(in: "````text\n```\ninner\n```\n````")
        #expect(longer.count == 1)
        #expect(longer.first?.body == "```\ninner\n```")
    }

    @Test func aDetailOfNothingButABadDiagramHasNoContent() {
        let d = detail("```mermaid\nsequenceDiagram\nA->>B: x\n```")
        #expect(!d.hasContent)
        #expect(d.deliveredMarkdown.isEmpty)
        #expect(d.dropped.count == 1)
    }

    @Test func aCodeBlockAndADiagramCanShareOneDocument() {
        let d = detail("""
            Sketch it, then start here.

            ```mermaid
            flowchart LR
            a[Client] --> b[API]
            ```

            ```python
            total = 0
            ```
            """)
        #expect(d.diagram != nil)
        #expect(d.code?.code == "total = 0")
        #expect(d.hasContent)
    }
}
