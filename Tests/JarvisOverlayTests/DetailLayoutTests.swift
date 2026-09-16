import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@MainActor
@Suite struct DetailLayoutTests {
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
        let text = try #require(document.subviews.compactMap { $0 as? NSTextView }.first)
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

    /// The hint box keeps a usable slice whatever the detail asks for.
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
