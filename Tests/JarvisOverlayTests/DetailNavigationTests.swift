import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DetailNavigationTests {
    @MainActor @Test func theBoxFollowsTheNewestReplyWithDetail() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        #expect(box.currentDetailPosition == "1 of 1")
        try deliver(box, "Add a cache.", "flowchart LR\nB[API] --> C[Cache]")
        #expect(box.currentDetailPosition == "2 of 2")
        #expect(box.currentDetail?.segments.count == 2)
        #expect(box.currentDetailProseText.contains("Add a cache."))
        #expect(box.currentDetailTitle.hasPrefix("DETAIL · FROM "))
    }

    @MainActor @Test func steppingBackHoldsTheBoxAndSteppingForwardResumesFollowing() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        try deliver(box, "Add a cache.", "flowchart LR\nB[API] --> C[Cache]")
        box.clickDetailPrevious()
        #expect(box.currentDetailPosition == "1 of 2")
        #expect(box.isDetailHeld)
        #expect(box.currentDetailProseText.contains("First sketch."))

        try deliver(box, "Shard the index.", "flowchart LR\nC[Cache] --> D[Shard]")
        #expect(box.currentDetailPosition == "1 of 3", "a held box does not take a later reply")
        #expect(box.currentDetailProseText.contains("First sketch."))

        box.clickDetailNext()
        box.clickDetailNext()
        #expect(box.currentDetailPosition == "3 of 3")
        #expect(!box.isDetailHeld)
        try deliver(box, "Then talk trade-offs.", "flowchart LR\nD[Shard] --> E[Replica]")
        #expect(box.currentDetailPosition == "4 of 4")
    }

    @MainActor @Test func pinHoldsTheNewestAndUnpinJumpsBackToIt() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        box.clickDetailPin()
        #expect(box.isDetailHeld)
        try deliver(box, "Add a cache.", "flowchart LR\nB[API] --> C[Cache]")
        #expect(box.currentDetailPosition == "1 of 2")
        #expect(box.currentDetailProseText.contains("First sketch."))

        box.clickClearButton()
        #expect(box.currentText.isEmpty)
        #expect(box.currentDetailProseText.contains("First sketch."))

        box.clickDetailPin()
        #expect(!box.isDetailHeld)
        #expect(box.currentDetailPosition == "2 of 2")
        #expect(box.currentDetailProseText.contains("Add a cache."))
    }

    @MainActor @Test func dismissRollsTheBoxDownToItsStripAndShowRestoresIt() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        let open = box.currentDetailHeight
        #expect(open > box.detailStripHeight)

        box.clickDetailDismiss()
        #expect(box.isDetailRolled)
        #expect(box.currentDetailHeight == box.detailStripHeight)
        #expect(!box.showsDiagram)
        #expect(box.currentDetailPosition == "1 of 1")

        box.clickDetailDismiss()
        #expect(!box.isDetailRolled)
        #expect(abs(box.currentDetailHeight - open) < 0.01)
        #expect(box.showsDiagram)
    }

    @MainActor @Test func aNewDetailOpensARolledBoxUnlessItIsHeld() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        box.clickDetailDismiss()
        try deliver(box, "Add a cache.", "flowchart LR\nB[API] --> C[Cache]")
        #expect(!box.isDetailRolled)

        box.clickDetailPin()
        box.clickDetailDismiss()
        try deliver(box, "Shard the index.", "flowchart LR\nC[Cache] --> D[Shard]")
        #expect(box.isDetailRolled)
        #expect(box.currentDetailPosition == "2 of 3")
    }

    @MainActor @Test func collapseHidesBothBoxesAndExpandRestoresThem() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        box.clickCollapseButton()
        #expect(box.currentDetailHeight == 0)
        #expect(!box.isLogVisible)
        box.clickCollapseButton()
        #expect(box.currentDetailHeight > 0)
        #expect(box.showsDiagram)
    }

    /// AppKit draws tooltips in its own window, outside the panel's capture exclusion.
    @MainActor @Test func theDetailControlsAreLabeledAndTooltipFree() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        #expect(box.detailButtonTooltips.allSatisfy { $0 == nil })
        #expect(box.detailButtonLabels.allSatisfy { $0?.isEmpty == false })
        #expect(box.currentSharingType == .none)
    }

    @MainActor @Test func bothStripsShareOneChromeAndFollowTheBoxSize() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        box.endLiveResize()
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        #expect(box.detailIconPointSize == box.headerIconPointSize)
        #expect(box.detailTitlePointSize == box.headerTitlePointSize)
        #expect(box.detailStripHeight == box.currentHeaderHeight)

        let small = box.detailIconPointSize
        box.setContentSize(NSSize(width: 520, height: 900))
        #expect(box.detailIconPointSize > small, "the strip grows with the box")
        #expect(box.detailIconPointSize == box.headerIconPointSize)
        #expect(box.detailTitlePointSize == box.headerTitlePointSize)
        #expect(box.detailStripHeight == box.currentHeaderHeight)
    }

    @MainActor @Test func aClickOnTheSettingsSampleDoesNotReachTheNextSession() throws {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        box.setEnabled(true)
        box.showAppearancePreview(true)
        #expect(box.currentDetail != nil, "the preview shows a sample detail")
        box.clickDetailPin()
        box.clickDetailDismiss()
        #expect(!box.isDetailHeld)
        #expect(!box.isDetailRolled)
        box.showAppearancePreview(false)

        box.setSessionLive(true)
        defer { box.setSessionLive(false) }
        try deliver(box, "First sketch.", "flowchart LR\nA[Client] --> B[API]")
        #expect(box.currentDetailPosition == "1 of 1")
        #expect(box.currentDetailProseText.contains("First sketch."))
        #expect(!box.isDetailHeld)
    }

    @MainActor @Test func navigationCommandsFollowTheArrowsAndIgnoreUnavailablePanels() throws {
        let box = try makeBox()
        defer { box.setSessionLive(false) }
        box.showPreviousDetail()
        box.showNextDetail()
        #expect(box.currentDetail == nil)
        try deliver(box, "First sketch.", "flowchart LR\nA --> B")
        try deliver(box, "Add a cache.", "flowchart LR\nB --> C")
        box.showPreviousDetail()
        #expect(box.currentDetailPosition == "1 of 2")
        #expect(box.isDetailHeld)
        box.clickDetailDismiss()
        box.showPreviousDetail()
        #expect(box.isDetailRolled, "the disabled previous arrow must be a no-op")
        box.showNextDetail()
        #expect(box.currentDetailPosition == "2 of 2")
        #expect(!box.isDetailHeld)
        #expect(!box.isDetailRolled)
        box.clickDetailPin()
        box.showNextDetail()
        #expect(box.isDetailHeld, "the disabled next arrow must not unpin")
        box.setEnabled(false)
        box.showPreviousDetail()
        #expect(box.currentDetailPosition == "2 of 2")
        box.setEnabled(true)
        box.clickCollapseButton()
        box.showPreviousDetail()
        #expect(box.currentDetailPosition == "2 of 2")
        box.clickCollapseButton()
        box.showPreviousDetail()
        try deliver(box, "Third detail.", "flowchart LR\nC --> D")
        #expect(box.currentDetailPosition == "1 of 3")
        box.showNextDetail()
        box.showNextDetail()
        #expect(box.currentDetailPosition == "3 of 3")
        #expect(!box.isDetailHeld)
        box.setSessionLive(false)
        box.showPreviousDetail()
        box.showNextDetail()
        #expect(box.currentDetail == nil)
    }

    @MainActor private func makeBox() throws -> OverlayBoxPanel {
        let box = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        box.setEnabled(true)
        box.setSessionLive(true)
        return box
    }

    @MainActor private func deliver(_ box: OverlayBoxPanel, _ text: String, _ mermaid: String) throws {
        let detail = try #require(ReplyDetail(markdown: "\(text)\n\n```mermaid\n\(mermaid)\n```"))
        #expect(box.deliver([text], perLineSeconds: [2], detail: detail) == detail)
    }
}
