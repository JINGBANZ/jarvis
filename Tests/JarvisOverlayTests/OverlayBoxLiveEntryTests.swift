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
        panel.showReplyProgress(progress(detail: "```java\nint"))
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Writing…"))
        panel.showReplyProgress(progress(open: "Use a", detail: "```java\nint i"))
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Use a"))
        #expect(!panel.currentText.contains("Writing…"))
        #expect(panel.detailCount == 0, "the detail reaches the box at delivery")
    }

    @MainActor @Test
    func aDeliveryWithNoLinesEndsTheLiveEntry() {
        let panel = liveBox()
        panel.showReplyProgress(progress(detail: "Only a detail"))
        #expect(panel.hasLiveEntry)
        #expect(panel.deliver([], detail: ReplyDetail(markdown: "Only a detail")) == nil)
        #expect(!panel.hasLiveEntry)
        #expect(panel.entryCount == 0, "nothing delivered, nothing left behind")
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
