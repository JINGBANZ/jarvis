import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite(.serialized) struct OverlayBoxScrollingTests {
    private let hint = "Check the empty list before reading its first item. Then move the left edge only after recording the current window, so the final candidate is included in the result."

    @MainActor @Test(arguments: [false, true], [false, true])
    func deliveredHintIsFullyVisibleAfterALongHistory(withDetail: Bool, scrolledUp: Bool) throws {
        let (panel, text) = try makeBoxWithHistory(scrolledUp: scrolledUp)
        defer { panel.setSessionLive(false) }
        let detail = withDetail ? ReplyDetail(markdown: "Record the window before moving its left edge.") : nil

        _ = panel.deliver(hint, detail: detail)

        try expectVisible(hint, in: text)
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func streamingHintStaysFullyVisibleAsItWraps(withDetail: Bool, scrolledUp: Bool) throws {
        let (panel, text) = try makeBoxWithHistory(scrolledUp: scrolledUp)
        defer { panel.setSessionLive(false) }
        let detail = withDetail ? "Record the window before moving its left edge." : nil

        for count in [8, 80, hint.count] {
            let partial = String(hint.prefix(count))
            panel.showReplyProgress(BrainReplyProgress(
                hint: partial, hintComplete: count == hint.count, detailMarkdown: detail))
            try expectVisible(partial, in: text)
        }
        _ = panel.deliver(hint, detail: detail.flatMap { ReplyDetail(markdown: $0) })
        try expectVisible(hint, in: text)
    }

    @MainActor @Test(arguments: [false, true])
    func updatesBeforeADrawStillRevealTheNewestHint(streamed: Bool) throws {
        let (panel, text) = try makeBoxWithHistory(scrolledUp: false, layoutBetweenHints: false)
        defer { panel.setSessionLive(false) }

        if streamed {
            panel.showReplyProgress(BrainReplyProgress(hint: hint, hintComplete: true, detailMarkdown: nil))
        } else {
            _ = panel.deliver(hint, detail: nil)
        }
        try expectVisible(hint, in: text)
    }

    @MainActor @Test
    func aHintTallerThanTheViewportKeepsItsEndingVisibleOnDelivery() throws {
        let (panel, text) = try makeBoxWithHistory(scrolledUp: false)
        defer { panel.setSessionLive(false) }
        panel.setContentSize(NSSize(width: 400, height: 220))
        let markdown = "Record the window before moving its left edge."
        panel.showReplyProgress(BrainReplyProgress(
            hint: hint, hintComplete: true, detailMarkdown: markdown))
        #expect(try textRect(hint, in: text).height > text.visibleRect.height)
        try expectVisible("included in the result.", in: text)

        _ = panel.deliver(hint, detail: ReplyDetail(markdown: markdown))

        try expectVisible("included in the result.", in: text)
        try expectVisible("detail below", in: text)
    }

    @MainActor private func makeBoxWithHistory(scrolledUp: Bool, layoutBetweenHints: Bool = true)
        throws -> (OverlayBoxPanel, NSTextView) {
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 400, height: 360))
        let window = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        panel.setSessionLive(true)
        let scroll = try #require(window.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(scroll.documentView as? NSTextView)
        for index in 0..<40 {
            _ = panel.deliver("Earlier hint \(index): keep track of both edges of the current window.", detail: nil)
            if layoutBetweenHints, let container = text.textContainer {
                text.layoutManager?.ensureLayout(for: container)
            }
        }
        if scrolledUp {
            text.scroll(.zero)
            #expect(text.visibleRect.minY == 0)
        }
        return (panel, text)
    }

    @MainActor private func expectVisible(_ hint: String, in text: NSTextView,
                                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rect = try textRect(hint, in: text)
        let visible = text.visibleRect
        #expect(rect.height <= visible.height, "the new hint fits in the history viewport", sourceLocation: sourceLocation)
        #expect(rect.minY >= visible.minY - 1 && rect.maxY <= visible.maxY + 1,
                "new hint spans \(rect.minY)...\(rect.maxY), visible history spans \(visible.minY)...\(visible.maxY)",
                sourceLocation: sourceLocation)
    }

    @MainActor private func textRect(_ hint: String, in text: NSTextView) throws -> NSRect {
        let layout = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        let range = (text.string as NSString).range(of: hint, options: .backwards)
        try #require(range.location != NSNotFound)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerInset.width, dy: text.textContainerInset.height)
    }
}
