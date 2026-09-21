import Testing
import AppKit
import JarvisCore
@testable import JarvisOverlay

/// Async tests are nonisolated wrappers that `await` a `@MainActor` helper: `@MainActor async
/// @Test` miscompiles on the bundled swift-testing toolchain.
// Serialized: NSPanel and its AppKit layout share the one main actor.
@Suite(.serialized) struct OverlayBoxPanelTests {

    @MainActor @Test
    func excludedFromScreenCaptureAtInit() {
        let panel = OverlayBoxPanel()
        #expect(panel.currentSharingType == .none)
    }

    @MainActor @Test
    func staysHiddenUntilASessionStarts() {
        let panel = OverlayBoxPanel()
        #expect(!panel.isPanelVisible, "the box must stay hidden until a session starts")
    }

    @MainActor @Test
    func sessionStartShowsTheBoxAndReassertsCaptureExclusion() {
        let panel = OverlayBoxPanel()
        let before = panel.captureExclusionReassertCount
        panel.setSessionLive(true)
        #expect(panel.isPanelVisible, "Start must put the box on screen")
        #expect(panel.captureExclusionReassertCount > before, "showing the box must re-assert capture exclusion")
        #expect(panel.currentSharingType == .none)
    }

    @MainActor @Test
    func sessionStopHidesTheBox() {
        let panel = liveBox()
        panel.setSessionLive(false)
        #expect(!panel.isPanelVisible, "Stop must take the box off screen")
    }

    @MainActor @Test
    func aClosedPreviewLeavesTheBoxToAppearOnStart() {
        let panel = OverlayBoxPanel()
        panel.showAppearancePreview(true)
        panel.showAppearancePreview(false)
        #expect(!panel.isPanelVisible, "still nothing to show: no session is running")
        panel.setSessionLive(true)
        #expect(panel.isPanelVisible, "the box must appear on the Start after a preview closes")
    }

    @MainActor @Test
    func aPreviewDoesNotOpenWhileASessionIsRunning() {
        let panel = liveBox()

        panel.showAppearancePreview(true)

        #expect(!panel.currentText.contains("Ask about the time complexity"),
                "the live box must keep showing the session's own log, not the sample")
    }

    @MainActor @Test
    func stoppingWithTheOverlayTabStillOpenBringsTheSampleUp() {
        let panel = liveBox()
        panel.showAppearancePreview(true)
        #expect(!panel.currentText.contains("Ask about the time complexity"))

        panel.setSessionLive(false)

        #expect(panel.currentText.contains("Ask about the time complexity"),
                "the standing request must be honoured once the session is gone")
        #expect(panel.isPanelVisible)
    }

    @MainActor @Test
    func stoppingWithNoPreviewRequestedJustHidesTheBox() {
        let panel = liveBox()
        panel.setSessionLive(false)
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test
    func startDoesNotInheritACollapseSnapshotFromAnOpenPreview() {
        let panel = liveBox()
        panel.clickCollapseButton()
        panel.setSessionLive(false)

        panel.showAppearancePreview(true)
        panel.setSessionLive(true)
        panel.showAppearancePreview(false)

        #expect(!panel.isCollapsed, "the new session's box must not inherit the old one's collapse")
        #expect(panel.isLogVisible)
    }

    @MainActor @Test
    func isResizableAndHonorsAResize() {
        let panel = OverlayBoxPanel()
        #expect(panel.isResizable, "the box must be resizable by dragging its edges")
        panel.setContentSize(NSSize(width: 500, height: 400))
        #expect(panel.currentContentSize.width == 500)
        #expect(panel.currentContentSize.height == 400)
    }

    @MainActor @Test
    func startsAtTheDefaultSizeUntilOneIsRestored() {
        let panel = OverlayBoxPanel()
        // Explicit Double(): #expect fails an implicit CGFloat/Double comparison even for equal
        // values.
        #expect(Double(panel.currentContentSize.width) == Defaults.Overlay.Box.width)
        #expect(Double(panel.currentContentSize.height) == Defaults.Overlay.Box.height)
    }

    @MainActor @Test
    func minimumSizeMatchesThePersistedRangeFloor() {
        let panel = OverlayBoxPanel()
        #expect(Double(panel.minimumContentSize.width)
            == Defaults.Overlay.Box.widthRange.lowerBound)
        #expect(Double(panel.minimumContentSize.height)
            == Defaults.Overlay.Box.heightRange.lowerBound)
    }

    @MainActor @Test
    func isConstructedAtASavedSize() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 900, height: 700))
        #expect(panel.currentContentSize.width == 900)
        #expect(panel.currentContentSize.height == 700)
    }

    @MainActor @Test
    func usesTheRegisteredOpacityBeforeAnySetterRuns() {
        let panel = OverlayBoxPanel()
        #expect(abs(panel.currentBoxOpacity - CGFloat(Defaults.Overlay.Box.opacity)) < 0.001)
    }

    @MainActor @Test
    func reportsTheNewSizeWhenAResizeDragFinishes() {
        let panel = OverlayBoxPanel()
        var reported: [(Double, Double)] = []
        panel.onSizeChanged = { reported.append(($0, $1)) }

        panel.setContentSize(NSSize(width: 520, height: 430))
        panel.endLiveResize()

        #expect(reported.count == 1)
        #expect(reported.first?.0 == 520)
        #expect(reported.first?.1 == 430)
    }

    @MainActor @Test
    func aProgrammaticResizeDoesNotReportAUserResize() {
        let panel = OverlayBoxPanel()
        var reportCount = 0
        panel.onSizeChanged = { _, _ in reportCount += 1 }

        panel.setContentSize(NSSize(width: 460, height: 360))

        #expect(reportCount == 0)
        #expect(panel.currentContentSize.width == 460)
    }

    @MainActor @Test
    func usesAutoHidingOverlayScroller() {
        let panel = OverlayBoxPanel()
        #expect(panel.currentScrollerStyle == .overlay,
                "the box must not inherit a persistent legacy scroller from the release SDK")
        #expect(panel.scrollersAutohide,
                "a short history must not leave an unnecessary scrollbar visible")
    }

    @MainActor @Test
    func appearanceSettersChangeOpacityAndFontSize() {
        let panel = OverlayBoxPanel()
        panel.setOpacity(0.5)
        panel.setFontSize(22)
        #expect(abs(panel.currentBoxOpacity - 0.5) < 0.001)
        #expect(panel.currentFontPointSize == 22)
    }

    @MainActor @Test
    func previewShowsSampleThenRestoresPriorState() {
        let panel = OverlayBoxPanel()
        let before = panel.captureExclusionReassertCount
        panel.showAppearancePreview(true)
        #expect(panel.isPanelVisible, "preview must show the box so size/opacity are visible")
        #expect(!panel.currentText.isEmpty, "preview must show sample text even with no responses yet")
        #expect(panel.captureExclusionReassertCount > before, "preview must re-assert capture exclusion")
        #expect(panel.currentSharingType == .none)
        #expect(panel.entryCount == 0, "the sample must not be logged as a real response")
        panel.showAppearancePreview(false)
        #expect(!panel.isPanelVisible, "closing the preview must restore the box's prior hidden state")
        #expect(panel.currentText.isEmpty, "the real (empty) log must be restored after preview")
    }

    @MainActor @Test
    func previewKeepsBoxShownIfItWasAlreadyOpen() {
        let panel = liveBox()
        panel.showAppearancePreview(true)
        panel.showAppearancePreview(false)
        #expect(panel.isPanelVisible, "a box open before preview must stay open after it closes")
    }

    @MainActor @Test
    func clearEmptiesTheLog() {
        let panel = OverlayBoxPanel()
        panel.render(["kept for now"])
        // No wait: append runs on a later main-actor hop, and clear must empty regardless.
        panel.clear()
        #expect(panel.entryCount == 0)
        #expect(panel.currentText.isEmpty)
    }

    // MARK: - Header

    @MainActor @Test
    func theHeaderIsSizedFromTheBox() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 140))
        #expect(panel.currentHeaderHeight == 26)
        panel.setContentSize(NSSize(width: 520, height: 900))
        #expect(panel.currentHeaderHeight == 44, "resizing the box must resize its header")
    }

    @MainActor @Test
    func collapsingLeavesOnlyTheHeaderOnScreen() {
        let panel = liveBox()
        panel.clickCollapseButton()
        #expect(panel.isCollapsed)
        #expect(panel.currentContentSize.height == panel.currentHeaderHeight)
        #expect(panel.currentContentSize.width == CGFloat(Defaults.Overlay.Box.width),
                "collapsing must not change the width the user dragged to")
        #expect(!panel.isLogVisible, "a collapsed box must not show the log under its header")
    }

    @MainActor @Test
    func expandingRestoresTheHeightTheUserDraggedTo() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 700))
        panel.clickCollapseButton()
        panel.clickCollapseButton()
        #expect(!panel.isCollapsed)
        #expect(panel.currentContentSize.height == 700)
        #expect(panel.isLogVisible)
    }

    @MainActor @Test
    func collapsingDoesNotReportAUserResize() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 700))
        var reportCount = 0
        panel.onSizeChanged = { _, _ in reportCount += 1 }

        panel.clickCollapseButton()
        panel.clickCollapseButton()

        #expect(reportCount == 0)
    }

    @MainActor @Test
    func aCollapsedBoxCannotBeDraggedTaller() {
        let panel = OverlayBoxPanel()
        panel.clickCollapseButton()
        #expect(panel.minimumContentSize.height == panel.currentHeaderHeight)
        #expect(panel.maximumContentSize.height == panel.currentHeaderHeight)

        panel.clickCollapseButton()
        #expect(panel.minimumContentSize.height
            == CGFloat(Defaults.Overlay.Box.heightRange.lowerBound), "expanding restores the drag floor")
        #expect(panel.maximumContentSize.height > panel.currentHeaderHeight,
                "expanding restores the drag ceiling")
    }

    @MainActor @Test
    func aNewSessionOpensACollapsedBox() {
        let panel = liveBox()
        panel.clickCollapseButton()
        panel.setSessionLive(false)
        panel.setSessionLive(true)
        #expect(!panel.isCollapsed)
        #expect(panel.isLogVisible)
    }

    @MainActor @Test
    func aWidthDragWhileCollapsedKeepsTheExpandedHeight() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 700))
        var reported: [(Double, Double)] = []
        panel.onSizeChanged = { reported.append(($0, $1)) }

        panel.clickCollapseButton()
        panel.setContentSize(NSSize(width: 640, height: panel.currentHeaderHeight))
        panel.endLiveResize()

        #expect(reported.count == 1)
        #expect(reported.first?.0 == 640)
        #expect(reported.first?.1 == 700, "the collapsed height must never become the saved height")
    }

    /// `setContentSize` keeps the top-left fixed only while the window is on screen; ordered out,
    /// it keeps the bottom-left. Stop orders the box out.
    @MainActor @Test
    func collapsingRollsTheBoxDownFromAFixedTopEdge() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        let before = panel.currentFrame

        panel.clickCollapseButton()
        #expect(panel.currentFrame.maxY == before.maxY, "the top edge must not move")
        #expect(panel.currentFrame.minX == before.minX)

        panel.clickCollapseButton()
        #expect(panel.currentFrame == before, "expanding must put the box back exactly")
    }

    /// AppKit draws tooltips in its own window, which does not inherit the panel's capture
    /// exclusion.
    @MainActor @Test
    func theHeaderButtonsCarryNoTooltipButKeepTheirLabels() {
        let panel = OverlayBoxPanel()
        #expect(panel.headerButtonTooltips.allSatisfy { $0 == nil })
        #expect(panel.headerButtonLabels == ["Collapse", "Clear history"],
                "dropping the tooltips must not cost the buttons their VoiceOver labels")
    }

    @MainActor @Test
    func theSettingsPreviewOffersNoClearButton() {
        let panel = OverlayBoxPanel()
        panel.showAppearancePreview(true)
        #expect(!panel.isClearButtonVisible)
        panel.showAppearancePreview(false)
        #expect(!panel.isClearButtonVisible, "the real log is still empty after the preview closes")
    }

    @MainActor @Test
    func theSettingsPreviewRollsACollapsedBoxOpenAndPutsItBack() {
        let panel = liveBox()
        panel.clickCollapseButton()
        panel.setSessionLive(false)   // the preview only opens while stopped

        panel.showAppearancePreview(true)
        #expect(panel.isLogVisible, "the sample must be on screen for the sliders to preview anything")
        #expect(!panel.isCollapsed)

        panel.showAppearancePreview(false)
        #expect(panel.isCollapsed, "a Settings visit must not spend the user's collapse")
        #expect(!panel.isLogVisible)
    }

    @Test
    func theClearButtonFollowsWhetherTheLogHasAnything() async {
        await checkClearButtonFollowsTheLog()
    }

    @Test
    func clearingDuringThePreviewCannotWipeTheSessionsLog() async {
        await checkPreviewClearLeavesTheLogAlone()
    }

    @Test
    func rendersAppendEachTipAsAnEntry() async {
        await checkAppendsEntries()
    }

    @Test
    func dropsEmptyAndWhitespaceOnlyTips() async {
        await checkDropsEmptyTips()
    }

    @Test
    func reassertsCaptureExclusionOnRenderWhileVisible() async {
        await checkReassertOnRenderWhileVisible()
    }

    @Test
    func responsesDuringPreviewAreRevealedAfterClose() async {
        await checkAppendDuringPreview()
    }
}

// MARK: - Main-actor checks (awaited from nonisolated tests so render's main-actor hop can run)

@MainActor private func liveBox() -> OverlayBoxPanel {
    let panel = OverlayBoxPanel()
    panel.setSessionLive(true)
    return panel
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let steps = max(1, Int(timeout / 0.02))
    for _ in 0..<steps {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func checkReassertOnRenderWhileVisible() async {
    let panel = liveBox()
    let before = panel.captureExclusionReassertCount
    panel.render(["A new response."])
    #expect(await waitUntil { panel.entryCount == 1 }, "the response should be logged")
    #expect(panel.captureExclusionReassertCount > before, "a render while visible must re-assert capture exclusion")
    #expect(panel.currentSharingType == .none)
}

@MainActor
private func checkAppendDuringPreview() async {
    let panel = OverlayBoxPanel()
    panel.showAppearancePreview(true)
    panel.render(["Mid-preview response."])
    #expect(await waitUntil { panel.entryCount == 1 }, "the response is logged even during preview")
    #expect(panel.currentText.contains("Ask about the time complexity"), "preview still shows the sample…")
    #expect(!panel.currentText.contains("Mid-preview response."), "…not the response that arrived during it")
    panel.showAppearancePreview(false)
    #expect(panel.currentText.contains("Mid-preview response."), "closing the preview reveals the mid-preview response")
    #expect(!panel.currentText.contains("Ask about the time complexity"), "the sample is gone after preview closes")
}

@MainActor
private func checkClearButtonFollowsTheLog() async {
    let panel = liveBox()
    #expect(!panel.isClearButtonVisible, "an empty box offers nothing to erase")
    panel.render(["A new response."])
    #expect(await waitUntil { panel.isClearButtonVisible }, "the first tip must reveal the clear button")

    panel.clickClearButton()
    #expect(panel.entryCount == 0, "the header button must erase the log")
    #expect(panel.currentText.isEmpty, "an erased box is blank, with no placeholder")
    #expect(!panel.isClearButtonVisible, "an erased box offers nothing to erase again")
}

@MainActor
private func checkPreviewClearLeavesTheLogAlone() async {
    let panel = liveBox()
    panel.render(["A real tip."])
    #expect(await waitUntil { panel.entryCount == 1 }, "the tip should be logged")
    panel.setSessionLive(false)          // the preview only opens while stopped

    panel.showAppearancePreview(true)
    panel.clickClearButton()
    panel.showAppearancePreview(false)

    #expect(panel.entryCount == 1, "the preview's clear button must not erase the session's log")
    #expect(panel.currentText.contains("A real tip."))
}

@MainActor
private func checkAppendsEntries() async {
    let panel = OverlayBoxPanel()
    panel.render(["Ask about the time complexity."])
    panel.render(["Mention", "the edge case."])

    #expect(await waitUntil { panel.entryCount == 2 }, "both tips should be logged")
    #expect(panel.currentText.contains("Ask about the time complexity."))
    #expect(panel.currentText.contains("Mention the edge case."), "a tip's lines join into one entry")
}

@MainActor
private func checkDropsEmptyTips() async {
    let panel = OverlayBoxPanel()
    panel.render([])
    panel.render(["   ", "", "\n\t"])
    try? await Task.sleep(nanoseconds: 200_000_000)   // lets an erroneous append run
    #expect(panel.entryCount == 0, "empty/whitespace-only tips must not be logged")
}
