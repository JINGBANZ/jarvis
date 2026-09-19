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
        panel.setEnabled(true)
        panel.setSessionLive(true)
        return panel
    }

    @MainActor @Test
    func theEntryOpensOnTheFirstClosedLineAndFollowsTheReply() {
        let panel = liveBox()
        panel.showReplyProgress(progress(open: "Sort by"), perLineSeconds: [])
        #expect(panel.entryCount == 0, "an open line alone does not open an entry")

        panel.showReplyProgress(progress(closed: ["Sort by start."], open: "Then"), perLineSeconds: [3])
        #expect(panel.entryCount == 1)
        #expect(panel.hasLiveEntry)
        #expect(panel.currentText.contains("Sort by start. Then"), "closed lines, then the open line")

        panel.showReplyProgress(progress(closed: ["Sort by start.", "Then merge."], complete: true), perLineSeconds: [3, 3])
        #expect(panel.entryCount == 1, "snapshots rewrite the entry rather than adding rows")
        #expect(panel.currentText.contains("Sort by start. Then merge."))
        #expect(!panel.currentText.contains("Then merge. Then"))
    }

    @MainActor @Test
    func deliverReplacesTheLiveEntryAndKeepsItsStamp() {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Sort by start."]), perLineSeconds: [3])
        let stamps = panel.entryStamps
        let detail = ReplyDetail(markdown: "Sort, then scan.")
        let shown = panel.deliver(["Sort by start.", "Then merge."], perLineSeconds: [3, 3], detail: detail)
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
        _ = panel.deliver(["Earlier."], perLineSeconds: [3], detail: nil)
        panel.showReplyProgress(progress(closed: ["Half way."]), perLineSeconds: [3])
        #expect(panel.entryCount == 2)
        panel.showReplyProgress(nil, perLineSeconds: [])
        #expect(panel.entryCount == 1)
        #expect(!panel.hasLiveEntry)
        #expect(!panel.currentText.contains("Half way."))
        #expect(panel.currentText.contains("Earlier."), "earlier entries are untouched")
    }

    @MainActor @Test
    func aDetailFirstReplyShowsAPlaceholderUntilItsFirstLineCloses() {
        let panel = liveBox()
        panel.showReplyProgress(progress(detail: "```java\nint"), perLineSeconds: [])
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Writing…"))
        panel.showReplyProgress(progress(closed: ["Use a loop."], detail: "```java\nint i"), perLineSeconds: [3])
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Use a loop."))
        #expect(!panel.currentText.contains("Writing…"))
        #expect(panel.detailCount == 0, "the detail reaches the box at delivery")
    }

    @MainActor @Test
    func clearRemovesALiveEntryLikeAnyOther() {
        let panel = liveBox()
        panel.showReplyProgress(progress(closed: ["Half way."]), perLineSeconds: [3])
        panel.clear()
        #expect(panel.entryCount == 0)
        #expect(!panel.hasLiveEntry)
        _ = panel.deliver(["Whole."], perLineSeconds: [3], detail: nil)
        #expect(panel.entryCount == 1, "a delivery after clear appends a fresh entry")
    }

    @MainActor @Test
    func theSamplePreviewIsUntouchedByProgress() {
        let panel = OverlayBoxPanel()
        panel.showAppearancePreview(true)
        panel.showReplyProgress(progress(closed: ["Mid-preview."]), perLineSeconds: [3])
        #expect(panel.currentText.contains("Ask about the time complexity"))
        #expect(!panel.currentText.contains("Mid-preview."))
        panel.showAppearancePreview(false)
        #expect(panel.currentText.contains("Mid-preview."), "the live entry is logged behind the sample")
    }
}
