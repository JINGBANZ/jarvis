import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@MainActor
@Suite struct CodeSnippetLayoutTests {
    @Test func longLinesWrapWithoutChangingCodeOrHighlights() throws {
        let snippet = try #require(CodeSnippet(language: "python", placement: "Inside the loop",
            code: "for index, value in enumerate(candidates, start=offset):\n    output[index] = transform(value)\n    last = value",
            highlightedLines: [1]))
        let dock = CodeSnippetView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        dock.show(snippet, fontSize: 32)
        dock.layoutSubtreeIfNeeded()
        let scroll = try #require(dock.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let text = try #require(document.subviews.compactMap { $0 as? NSTextView }.first)
        #expect(document.frame.width <= scroll.contentSize.width)
        #expect(document.frame.height <= scroll.contentSize.height)
        #expect(dock.codeText.string == snippet.code)
        #expect(dock.codeText.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        var fragments = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
            fragments += 1
        }
        #expect(fragments > 3)
    }

    @Test func compactCodeFitsWithoutScrollingAndRecoversSizeWhenRoomReturns() throws {
        let snippet = try #require(CodeSnippet(language: "swift", placement: "Current component",
            code: (1...6).map { "let item\($0) = \($0)" }.joined(separator: "\n")))
        let dock = CodeSnippetView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        dock.show(snippet, fontSize: 32)
        dock.layoutSubtreeIfNeeded()
        let scroll = try #require(dock.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let compactFont = try #require(dock.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(compactFont.pointSize >= 12)
        #expect(compactFont.pointSize < 18)
        #expect(document.frame.height <= scroll.contentSize.height)
        dock.setFrameSize(NSSize(width: 640, height: 320))
        dock.needsLayout = true
        dock.layoutSubtreeIfNeeded()
        let restoredFont = try #require(dock.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(restoredFont.pointSize == 18)
        #expect(dock.codeText.string == snippet.code)
        #expect(document.frame.width <= scroll.contentSize.width)
    }

    @Test func dockGrowsForWrappedLinesWhenPanelHasRoom() throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 320, height: 800))
        box.setEnabled(true)
        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        box.setCodeEnabled(true)
        let short = try #require(CodeSnippet(language: "swift", placement: "Current component", code: "return result"))
        #expect(box.deliverCodeSnippet(short) == short)
        let shortHeight = box.currentCodeHeight
        let long = try #require(CodeSnippet(language: "swift", placement: "Current component",
            code: "let matchingCandidates = candidates.filter { candidate in candidate.isValid && candidate.score > minimumScore }"))
        #expect(box.deliverCodeSnippet(long) == long)
        #expect(box.currentCodeHeight > shortHeight)
        #expect(box.currentCodeHeight <= 360)
    }

    @Test func tinyViewportKeepsAllCodeReachableAtReadableSize() throws {
        let snippet = try #require(CodeSnippet(language: "text", placement: "Current component",
            code: String(repeating: "a", count: 220)))
        let dock = CodeSnippetView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        dock.show(snippet, fontSize: 32)
        dock.layoutSubtreeIfNeeded()
        let scroll = try #require(dock.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let font = try #require(dock.codeText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize >= 12)
        #expect(document.frame.width <= scroll.contentSize.width)
        #expect(document.frame.height > scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height))
        #expect(scroll.contentView.bounds.maxY >= document.frame.maxY)
        #expect(dock.codeText.string == snippet.code)
    }
}
