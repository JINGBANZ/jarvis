import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@MainActor
@Suite struct DetailLayoutTests {
    @Test func aSentenceAfterACodeBlockIsDrawnBelowIt() throws {
        let detail = try #require(ReplyDetail(markdown: """
            First, track the last index.

            ```python
            last_seen = {}
            ```

            Then handle the empty string.
            """))
        #expect(try stackedText(detail) == ["First, track the last index.",
                                            "last_seen = {}",
                                            "Then handle the empty string."])
    }

    @Test func aNoteAfterADiagramIsDrawnBelowItAndTheDiagramFitsWhatTheTextLeaves() throws {
        let detail = try #require(ReplyDetail(markdown: """
            Sketch the read path.

            ```mermaid
            flowchart TD
            A[Client] --> B[API]
            B --> C[Database]
            ```

            The API owns the cache.
            """))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: 14)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let stacked = document.subviews.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(stacked.map { $0.accessibilityLabel() } == ["Detail", "Diagram", "Detail"])
        #expect((stacked.last as? NSTextView)?.string == "The API owns the cache.")
        #expect(stacked[1].frame.maxY <= stacked[2].frame.minY)
        #expect(document.frame.height <= scroll.contentSize.height,
                "the note below the diagram counts against the space the diagram scales into")
    }

    /// Top to bottom, as drawn.
    private func stackedText(_ detail: ReplyDetail) throws -> [String] {
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: 14)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        return document.subviews.compactMap { $0 as? NSTextView }
            .filter { !$0.isHidden }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.string)
    }

    @Test func longLinesWrapWithoutChangingTheCode() throws {
        let detail = try #require(ReplyDetail(markdown: """
            ```python
            for index, value in enumerate(candidates, start=offset):
                output[index] = transform(value)
                last = value
            ```
            """))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: 32)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        // Find the code view by label: a prose view is also an NSTextView.
        let views = document.subviews.compactMap { $0 as? NSTextView }
        let text = try #require(views.first { $0.accessibilityLabel() == "Code block" })
        #expect(!views.contains { $0.accessibilityLabel() == "Detail" })
        #expect(document.frame.width <= scroll.contentSize.width)
        #expect(document.frame.height <= scroll.contentSize.height)
        #expect(view.codeText.string == detail.code?.code)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        var fragments = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
            fragments += 1
        }
        #expect(fragments > 3)
    }

    @Test func compactContentFitsWithoutScrollingAndRecoversSizeWhenRoomReturns() throws {
        let code = (1...6).map { "let item\($0) = \($0)" }.joined(separator: "\n")
        let detail = try #require(ReplyDetail(markdown: "```swift\n\(code)\n```"))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: 32)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let compactFont = try #require(view.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(compactFont.pointSize >= 12)
        #expect(compactFont.pointSize < 18)
        #expect(document.frame.height <= scroll.contentSize.height)
        view.setFrameSize(NSSize(width: 640, height: 320))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let restoredFont = try #require(view.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(restoredFont.pointSize == 18)
        #expect(view.codeText.string == code)
        #expect(document.frame.width <= scroll.contentSize.width)
    }

    @Test func theBoxGrowsForWrappedContentWhenThePanelHasRoom() throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 320, height: 800))
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        let short = try #require(ReplyDetail(markdown: "```swift\nreturn result\n```"))
        #expect(box.deliver(["Return it."], perLineSeconds: [1], detail: short) == short)
        let shortHeight = box.currentDetailHeight
        let long = try #require(ReplyDetail(markdown:
            "```swift\nlet matchingCandidates = candidates.filter { candidate in candidate.isValid && candidate.score > minimumScore }\n```"))
        #expect(box.deliver(["Filter them."], perLineSeconds: [1], detail: long) == long)
        #expect(box.currentDetailHeight > shortHeight)
        #expect(box.currentDetailHeight <= 360)
    }

    @Test(arguments: [String(repeating: "a", count: 220),
                      (1...24).map { "    values.append(\($0))" }.joined(separator: "\n")])
    func aTinyViewportKeepsAllContentReachableAtAReadableSize(_ code: String) throws {
        let detail = try #require(ReplyDetail(markdown: "```text\n\(code)\n```"))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        view.show(detail, stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false,
                  fontSize: 32)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let font = try #require(view.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize >= 12)
        #expect(document.frame.width <= scroll.contentSize.width)
        #expect(document.frame.height > scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height))
        #expect(scroll.contentView.bounds.maxY >= document.frame.maxY)
        #expect(view.codeText.string == code)
    }

    @Test func theHintBoxKeepsSpaceAtTheMinimumPanelSize() throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        box.setContentSize(box.minimumContentSize)
        let code = (1...24).map { "    values.append(\($0))" }.joined(separator: "\n")
        let detail = try #require(ReplyDetail(markdown: "```python\n\(code)\n```"))
        _ = box.deliver(["Fill the list."], perLineSeconds: [1], detail: detail)
        #expect(box.currentDetailHeight > 0)
        #expect(box.currentDetailHeight <= box.currentContentSize.height - 44)
    }
}
