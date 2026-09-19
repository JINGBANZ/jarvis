import Testing
import AppKit
import JarvisCore
@testable import JarvisOverlay

// Serialized: NSPanel and its AppKit layout share the one main actor.
@Suite(.serialized) struct OverlayBoxLiveEntryTests {
    private func progress(closed: [String] = [], open: String? = nil, complete: Bool = false,
                          detail: String? = nil) -> BrainReplyProgress {
        BrainReplyProgress(closedLines: closed, openLine: open, linesComplete: complete, detailMarkdown: detail)
    }

    @MainActor private func liveBox() -> OverlayBoxPanel {
        let panel = OverlayBoxPanel()
        panel.setSessionLive(true)
        return panel
    }

    @MainActor @Test
    func theEntryOpensOnTheFirstCharacterAndFollowsTheReply() {
        let panel = liveBox()
        panel.showReplyProgress(progress(open: "  "))
        #expect(panel.entryCount == 0, "blank text opens nothing")

        panel.showReplyProgress(progress(open: "Sort by"))
        #expect(panel.entryCount == 1, "a half-written first line opens the entry")
        #expect(panel.hasLiveEntry)
        #expect(panel.currentText.contains("Sort by"))
        let stamps = panel.entryStamps

        panel.showReplyProgress(progress(closed: ["Sort by start."], open: "Then"))
        #expect(panel.entryCount == 1)
        #expect(panel.entryStamps == stamps, "the entry keeps the moment its first character arrived")
        #expect(panel.currentText.contains("Sort by start. Then"), "closed lines, then the open line")

        panel.showReplyProgress(progress(closed: ["Sort by start.", "Then merge."], complete: true))
        #expect(panel.entryCount == 1, "snapshots rewrite the entry rather than adding rows")
        #expect(panel.currentText.contains("Sort by start. Then merge."))
        #expect(!panel.currentText.contains("Then merge. Then"))
    }

    @MainActor @Test
    func deliverReplacesTheLiveEntryAndKeepsItsStamp() {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Sort by start."]))
        let stamps = panel.entryStamps
        let detail = ReplyDetail(markdown: "Sort, then scan.")
        let shown = panel.deliver(["Sort by start.", "Then merge."], detail: detail)
        #expect(shown == detail)
        #expect(panel.entryCount == 1, "deliver finalizes the live entry instead of appending")
        #expect(!panel.hasLiveEntry)
        #expect(panel.entryStamps == stamps, "the entry keeps the time its text first arrived")
        #expect(panel.currentText.contains("Sort by start. Then merge."))
        #expect(panel.currentText.contains("detail below"))
        #expect(panel.currentDetail == detail)
        #expect(panel.detailCount == 1)
    }

    @MainActor @Test
    func nilRemovesTheLiveEntry() {
        let panel = liveBox()
        _ = panel.deliver(["Earlier."], detail: nil)
        panel.showReplyProgress(progress(closed: ["Half way."]))
        #expect(panel.entryCount == 2)
        panel.showReplyProgress(nil)
        #expect(panel.entryCount == 1)
        #expect(!panel.hasLiveEntry)
        #expect(!panel.currentText.contains("Half way."))
        #expect(panel.currentText.contains("Earlier."), "earlier entries are untouched")
    }

    @MainActor @Test
    func nilRemovesAHalfWrittenFirstLine() {
        let panel = liveBox()
        panel.showReplyProgress(progress(open: "Sort by"))
        #expect(panel.hasLiveEntry)
        panel.showReplyProgress(nil)
        #expect(panel.entryCount == 0)
        #expect(!panel.hasLiveEntry)
        #expect(!panel.currentText.contains("Sort by"))
    }

    @MainActor @Test
    func aDetailFirstReplyShowsAPlaceholderUntilItsFirstLineStarts() {
        let panel = liveBox()
        panel.showReplyProgress(progress(detail: "```java\nint i = 0;\n"))
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Writing…"))
        #expect(panel.detailCount == 1, "the detail shows before line 1 starts")
        #expect(panel.currentDetail?.code?.code == "int i = 0;")
        panel.showReplyProgress(progress(open: "Use a", detail: "```java\nint i = 0;\nint j"))
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Use a"))
        #expect(!panel.currentText.contains("Writing…"))
        #expect(panel.detailCount == 1)
        #expect(panel.currentDetail?.code?.code == "int i = 0;", "an unfinished code line waits for its newline")
    }

    @MainActor @Test
    func theLiveDetailGrowsWithTheReplyAndIsFiledOnce() {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Move the left edge."], detail: "Use a window.\n\n```python\nleft = 0\n"))
        #expect(panel.detailCount == 1)
        #expect(panel.currentDetailPosition == "1 of 1")
        #expect(panel.currentDetail?.code?.code == "left = 0")
        #expect(panel.currentDetailTitle == "DETAIL · FROM \(panel.entryStamps[0])")
        #expect(panel.currentText.contains("detail below"), "the live entry carries the marker once its detail shows")

        panel.showReplyProgress(progress(closed: ["Move the left edge."], detail: "Use a window.\n\n```python\nleft = 0\nright = 0\n"))
        #expect(panel.detailCount == 1, "snapshots rewrite the detail rather than filing another")
        #expect(panel.currentDetailPosition == "1 of 1")
        #expect(panel.currentDetail?.code?.code == "left = 0\nright = 0")
    }

    @MainActor @Test
    func deliverReplacesTheLiveDetailWithTheDeliveredOne() throws {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Move the left edge."], detail: "Use a window.\n\n```python\nleft = 0\n"))
        let delivered = try #require(ReplyDetail(markdown: "Use a window.\n\n```python\nleft = 0\nright = 0\n```\n\nThen scan."))
        let shown = panel.deliver(["Move the left edge."], detail: delivered)
        #expect(shown == delivered)
        #expect(panel.detailCount == 1, "deliver finalizes the live detail instead of filing a second")
        #expect(panel.currentDetail == delivered)
        #expect(panel.currentDetailPosition == "1 of 1")
        #expect(panel.entryCount == 1)
        #expect(!panel.hasLiveEntry)
        #expect(panel.currentText.contains("detail below"))
    }

    @MainActor @Test
    func aDetailTheBoxCannotAcceptAtDeliveryIsDroppedWhole() throws {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Move the left edge."], detail: "Use a window.\n\n```python\nleft = 0\n"))
        #expect(panel.detailCount == 1)
        panel.clickCollapseButton()
        let delivered = try #require(ReplyDetail(markdown: "Use a window.\n\n```python\nleft = 0\n```"))
        #expect(panel.deliver(["Move the left edge."], detail: delivered) == nil)
        #expect(panel.detailCount == 0, "a detail the collapsed box never showed leaves the history too")
        panel.clickCollapseButton()
        #expect(panel.currentDetail == nil)
        #expect(!panel.currentText.contains("detail below"))
        #expect(panel.entryCount == 1)
    }

    @MainActor @Test
    func nilRemovesTheLiveDetailAndTheBoxReturnsToTheEarlierOne() throws {
        let panel = liveBox()
        let earlier = try #require(ReplyDetail(markdown: "Sort, then scan."))
        _ = panel.deliver(["Sort by start."], detail: earlier)
        panel.showReplyProgress(progress(closed: ["Half way."], detail: "Use a window.\n\n```python\nleft = 0\n"))
        #expect(panel.detailCount == 2)
        #expect(panel.currentDetailPosition == "2 of 2")
        panel.showReplyProgress(nil)
        #expect(panel.detailCount == 1)
        #expect(panel.currentDetail == earlier)
        #expect(panel.currentDetailPosition == "1 of 1")
        #expect(panel.entryCount == 1)
        #expect(!panel.currentText.contains("Half way."))
    }

    @MainActor @Test
    func aHeldDetailIsNotDisplacedByALiveOne() throws {
        let panel = liveBox()
        let earlier = try #require(ReplyDetail(markdown: "Sort, then scan."))
        _ = panel.deliver(["Sort by start."], detail: earlier)
        panel.clickDetailPin()
        panel.showReplyProgress(progress(closed: ["Move the left edge."], detail: "Use a window.\n\n```python\nleft = 0\n"))
        #expect(panel.detailCount == 2)
        #expect(panel.currentDetail == earlier)
        #expect(panel.currentDetailPosition == "1 of 2")
        let delivered = try #require(ReplyDetail(markdown: "Use a window.\n\n```python\nleft = 0\n```"))
        #expect(panel.deliver(["Move the left edge."], detail: delivered) == delivered)
        #expect(panel.detailCount == 2)
        #expect(panel.currentDetail == earlier)
        #expect(panel.currentDetailPosition == "1 of 2")
        panel.clickDetailPin()
        #expect(panel.currentDetail == delivered)
    }

    @MainActor @Test
    func aDetailThatGrowsKeepsTheReadersScrollPosition() throws {
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        func code(lines: Int) throws -> ReplyDetail {
            try #require(ReplyDetail(markdown: "```text\n"
                + (1...lines).map { "    values.append(\($0))" }.joined(separator: "\n") + "\n```"))
        }
        view.show(try code(lines: 16), stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false, fontSize: 18)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        #expect(scroll.contentView.bounds.origin.y == 40)

        view.show(try code(lines: 20), stamp: "10:30:00", position: (0, 1), isHeld: false, isRolled: false, fontSize: 18)
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.y == 40, "the same detail growing keeps the reader's place")

        view.show(try code(lines: 20), stamp: "10:30:09", position: (1, 2), isHeld: false, isRolled: false, fontSize: 18)
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.y == 0, "a different reply's detail opens at the top")
    }

    @MainActor @Test
    func aDeliveryWithNoLinesEndsTheLiveEntry() {
        let panel = liveBox()
        panel.showReplyProgress(progress(detail: "Only a detail"))
        #expect(panel.hasLiveEntry)
        #expect(panel.detailCount == 1)
        #expect(panel.deliver([], detail: ReplyDetail(markdown: "Only a detail")) == nil)
        #expect(!panel.hasLiveEntry)
        #expect(panel.entryCount == 0, "nothing delivered, nothing left behind")
        #expect(panel.detailCount == 0)
        #expect(!panel.currentText.contains("Writing…"))
    }

    @MainActor @Test
    func clearRemovesALiveEntryLikeAnyOther() {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Half way."]))
        panel.clear()
        #expect(panel.entryCount == 0)
        #expect(!panel.hasLiveEntry)
        _ = panel.deliver(["Whole."], detail: nil)
        #expect(panel.entryCount == 1, "a delivery after clear appends a fresh entry")
    }

    @MainActor @Test
    func theSamplePreviewIsUntouchedByProgress() {
        let panel = OverlayBoxPanel()
        panel.showAppearancePreview(true)
        panel.showReplyProgress(progress(closed: ["Mid-preview."]))
        #expect(panel.currentText.contains("Ask about the time complexity"))
        #expect(!panel.currentText.contains("Mid-preview."))
        panel.showAppearancePreview(false)
        #expect(panel.currentText.contains("Mid-preview."), "the live entry is logged behind the sample")
    }
}
