import Testing
import AppKit
import JarvisCore
@testable import JarvisOverlay

/// Tests for the Overlay Box (the persistent response-history window): it must stay excluded from
/// screen capture (the same privacy guarantee as the caption), accumulate each spoken tip, switch on
/// and off, and clear.
///
/// Like `OverlayInvisibilityTests`, the synchronous checks are `@MainActor @Test` (the async +
/// @MainActor @Test combination miscompiles on the bundled swift-testing toolchain), while anything
/// that needs `render`'s main-actor hop to run is a nonisolated `@Test` awaiting a `@MainActor` helper.
// NSPanel and its AppKit layout live on the one main actor. Keep this OS-bound suite sequential while
// Foundation-only suites continue to use Swift Testing's default parallel execution.
@Suite(.serialized) struct OverlayBoxPanelTests {

    @MainActor @Test
    func requestErrorUsesExistingCaptureExcludedPanel() {
        let panel = OverlayBoxPanel()
        panel.setEnabled(true)
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        panel.showError("Model request failed — try again.")
        #expect(panel.currentText.contains("Model request failed — try again."))
        #expect(panel.entryCount == 1)
        #expect(panel.isPanelVisible)
        #expect(panel.currentSharingType == .none)
    }

    @MainActor @Test
    func excludedFromScreenCaptureAtInit() {
        let panel = OverlayBoxPanel()
        #expect(panel.currentSharingType == .none)
    }

    // The box is a session surface: switched on in Settings it still stays off screen until Start,
    // and goes away again on Stop, so a stopped Jarvis leaves nothing on the desktop.
    @MainActor @Test
    func staysHiddenWhileSwitchedOnUntilASessionStarts() {
        let panel = OverlayBoxPanel()
        panel.setEnabled(true)
        #expect(!panel.isPanelVisible, "a box switched on must stay hidden until a session starts")
    }

    @MainActor @Test
    func sessionStartShowsTheBoxAndReassertsCaptureExclusion() {
        let panel = OverlayBoxPanel()
        panel.setEnabled(true)
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
    func sessionStartLeavesASwitchedOffBoxHidden() {
        let panel = OverlayBoxPanel()
        panel.setEnabled(false)
        panel.setSessionLive(true)
        #expect(!panel.isPanelVisible, "the Settings switch stays the master off switch")
    }

    @MainActor @Test
    func setEnabledShowsAndHidesTheBoxDuringASession() {
        let panel = OverlayBoxPanel()
        panel.setSessionLive(true)
        panel.setEnabled(true)            // off → shown
        #expect(panel.isPanelVisible)
        #expect(panel.currentSharingType == .none, "showing the box must keep it excluded from capture")
        panel.setEnabled(false)           // shown → hidden
        #expect(!panel.isPanelVisible)
    }

    // The enable checkbox fires while the Overlay tab is active, i.e. while a preview owns the box.
    // Switching off mid-preview must not tear down the sample, but must take effect on close.
    @MainActor @Test
    func setEnabledOffDuringPreviewHidesOnClose() {
        let panel = OverlayBoxPanel()
        panel.setEnabled(true)             // box on
        panel.showAppearancePreview(true)  // preview owns it
        panel.setEnabled(false)            // user switches it off mid-preview (deferred)
        #expect(panel.isPanelVisible, "the preview sample must stay up until the tab closes")
        panel.showAppearancePreview(false) // close the tab
        #expect(!panel.isPanelVisible, "a box switched off during preview must be ordered out on close")
    }

    // Symmetric: a box switched on during a preview must appear when its session starts.
    @MainActor @Test
    func setEnabledOnDuringPreviewShowsAtTheNextStart() {
        let panel = OverlayBoxPanel()      // starts hidden
        panel.showAppearancePreview(true)
        panel.setEnabled(true)             // user switches it on mid-preview
        panel.showAppearancePreview(false) // close the tab
        #expect(!panel.isPanelVisible, "still nothing to show: no session is running")
        panel.setSessionLive(true)
        #expect(panel.isPanelVisible, "a box switched on during preview must appear on Start")
    }

    /// The preview exists to give the sliders something to look at when the box is not on screen.
    /// During a session it already is on screen carrying the conversation's own tips, and the sliders
    /// apply to it live, so sample text would replace real content with something worse.
    @MainActor @Test
    func aPreviewDoesNotOpenWhileASessionIsRunning() {
        let panel = liveBox()

        panel.showAppearancePreview(true)

        #expect(!panel.currentText.contains("Ask about the time complexity"),
                "the live box must keep showing the session's own log, not the sample")
    }

    /// Settings cannot see the session, so it asks for the sample once when its Overlay tab opens and
    /// never asks again. Stopping without leaving that tab must therefore bring the sample up on its
    /// own, or the sliders are left with nothing on screen to act on.
    @MainActor @Test
    func stoppingWithTheOverlayTabStillOpenBringsTheSampleUp() {
        let panel = liveBox()
        panel.showAppearancePreview(true)   // asked while the session runs, so declined for now
        #expect(!panel.currentText.contains("Ask about the time complexity"))

        panel.setSessionLive(false)         // Stop, without leaving the tab

        #expect(panel.currentText.contains("Ask about the time complexity"),
                "the standing request must be honoured once the session is gone")
        #expect(panel.isPanelVisible)
    }

    /// The mirror: with no tab open, Stop simply takes the box away.
    @MainActor @Test
    func stoppingWithNoPreviewRequestedJustHidesTheBox() {
        let panel = liveBox()
        panel.setSessionLive(false)
        #expect(!panel.isPanelVisible)
    }

    /// Reported twice on the PR. Collapse during a session, Stop, open the preview (which expands the
    /// box and snapshots "was collapsed"), then Start without closing Settings: that snapshot used to
    /// survive and roll the new session's box up when Settings finally closed.
    @MainActor @Test
    func startDoesNotInheritACollapseSnapshotFromAnOpenPreview() {
        let panel = liveBox()
        panel.clickCollapseButton()
        panel.setSessionLive(false)

        panel.showAppearancePreview(true)   // expands, and snapshots "was collapsed"
        panel.setSessionLive(true)          // Start with Settings still open
        panel.showAppearancePreview(false)  // Settings closes afterwards

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
        // Convert explicitly: an implicit CGFloat/Double comparison inside #expect fails even for
        // bit-identical values, because the macro rewrites the expression around the conversion.
        #expect(Double(panel.currentContentSize.width) == Defaults.Overlay.Box.width)
        #expect(Double(panel.currentContentSize.height) == Defaults.Overlay.Box.height)
    }

    /// The drag floor must match the persisted floor, so a dragged size always survives a round trip
    /// through `OverlayAppearance` unchanged.
    @MainActor @Test
    func minimumSizeMatchesThePersistedRangeFloor() {
        let panel = OverlayBoxPanel()
        #expect(Double(panel.minimumContentSize.width)
            == Defaults.Overlay.Box.widthRange.lowerBound)
        #expect(Double(panel.minimumContentSize.height)
            == Defaults.Overlay.Box.heightRange.lowerBound)
    }

    /// The saved size arrives through `init`, so the panel is built at its final size and centered
    /// once. Placement needs no assertion of its own: with no post-construction resize, nothing is
    /// left to push the box off the centre `init` chose.
    @MainActor @Test
    func isConstructedAtASavedSize() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 900, height: 700))
        #expect(panel.currentContentSize.width == 900)
        #expect(panel.currentContentSize.height == 700)
    }

    /// The panel must carry the registered opacity on its own, not only when AppDelegate applies it.
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

        // Drive the real AppKit entry point rather than a test-only seam: `endLiveResize` is what
        // the window calls when the user lets go of a resized edge.
        panel.setContentSize(NSSize(width: 520, height: 430))
        panel.endLiveResize()

        #expect(reported.count == 1)
        #expect(reported.first?.0 == 520)
        #expect(reported.first?.1 == 430)
    }

    /// A programmatic resize must not read back as a user edit; otherwise a launch could rewrite
    /// the preference from whatever AppKit happened to settle on.
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
        // Box starts hidden; opening the preview shows it with sample text and re-asserts exclusion.
        let before = panel.captureExclusionReassertCount
        panel.showAppearancePreview(true)
        #expect(panel.isPanelVisible, "preview must show the box so size/opacity are visible")
        #expect(!panel.currentText.isEmpty, "preview must show sample text even with no responses yet")
        #expect(panel.captureExclusionReassertCount > before, "preview must re-assert capture exclusion")
        #expect(panel.currentSharingType == .none)
        #expect(panel.entryCount == 0, "the sample must not be logged as a real response")
        // Closing it restores the prior (hidden) state and clears the sample.
        panel.showAppearancePreview(false)
        #expect(!panel.isPanelVisible, "closing the preview must restore the box's prior hidden state")
        #expect(panel.currentText.isEmpty, "the real (empty) log must be restored after preview")
    }

    @MainActor @Test
    func previewKeepsBoxShownIfItWasAlreadyOpen() {
        let panel = liveBox()              // the box was open, a session running
        panel.showAppearancePreview(true)
        panel.showAppearancePreview(false)
        #expect(panel.isPanelVisible, "a box open before preview must stay open after it closes")
    }

    @MainActor @Test
    func clearEmptiesTheLog() {
        let panel = OverlayBoxPanel()
        panel.render(["kept for now"], perLineSeconds: 0)
        // (append runs on the next main-actor hop; clear must empty regardless of pending entries)
        panel.clear()
        #expect(panel.entryCount == 0)
        #expect(panel.currentText.isEmpty)
    }

    // MARK: - Header

    /// The header carries no fixed numbers: it is derived from the box's content height, so the same
    /// panel at two sizes gets two headers. Driven through `setContentSize` because that is what a
    /// finished resize drag leaves the window at.
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

    /// Collapsing is not a resize. If it reported one, the collapsed height would overwrite the size
    /// the user dragged to and come back at the next launch.
    @MainActor @Test
    func collapsingDoesNotReportAUserResize() {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 700))
        var reportCount = 0
        panel.onSizeChanged = { _, _ in reportCount += 1 }

        panel.clickCollapseButton()
        panel.clickCollapseButton()

        #expect(reportCount == 0)
    }

    /// Collapsed, the height is the header's, so pinning the drag floor to the drag ceiling is what
    /// stops a vertical drag from stretching a box with nothing in it.
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

    /// Collapse belongs to the conversation it was made during. Nothing persists it, and a fresh
    /// Start must not hand the user a box they have to reopen before they can read it.
    @MainActor @Test
    func aNewSessionOpensACollapsedBox() {
        let panel = liveBox()
        panel.clickCollapseButton()
        panel.setSessionLive(false)
        panel.setSessionLive(true)
        #expect(!panel.isCollapsed)
        #expect(panel.isLogVisible)
    }

    /// The horizontal edges stay draggable while collapsed, so a width drag has to persist the width
    /// the user just chose alongside the height they last dragged to, never the header's.
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

    /// `setContentSize` anchors a window's top-left only while it is on screen, and its bottom-left
    /// once ordered out. Stop orders the box out, so leaning on it meant a box collapsed before Stop
    /// expanded upward on the next Start and came back a screenful above where the user left it.
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

    /// A tooltip is drawn in a window of AppKit's own, which does not inherit this panel's capture
    /// exclusion, so one resting under the pointer would appear on the interviewer's screen share.
    @MainActor @Test
    func theHeaderButtonsCarryNoTooltipButKeepTheirLabels() {
        let panel = OverlayBoxPanel()
        #expect(panel.headerButtonTooltips.allSatisfy { $0 == nil })
        #expect(panel.headerButtonLabels == ["Collapse", "Clear history"],
                "dropping the tooltips must not cost the buttons their VoiceOver labels")
    }

    /// The sample is not the user's log, so there is nothing there to erase. Offering the button
    /// anyway would put a control on screen that does nothing when pressed.
    @MainActor @Test
    func theSettingsPreviewOffersNoClearButton() {
        let panel = OverlayBoxPanel()
        panel.showAppearancePreview(true)
        #expect(!panel.isClearButtonVisible)
        panel.showAppearancePreview(false)
        #expect(!panel.isClearButtonVisible, "the real log is still empty after the preview closes")
    }

    /// A collapsed box shows no log, so its sample would be invisible and the text-size slider would
    /// preview nothing. The preview rolls it open and hands the collapse back on close.
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

/// A box in the only state that puts it on screen: switched on in Settings, with a session running.
@MainActor private func liveBox() -> OverlayBoxPanel {
    let panel = OverlayBoxPanel()
    panel.setEnabled(true)
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

// A render that reaches the screen (box visible) must re-assert capture exclusion — the same
// defense-in-depth as OverlayCaptionPanel.show, so the box can't be left capturable after an activation-policy
// flip. Only becoming visible/append-while-visible bump the counter, so an increase proves the re-assert ran.
@MainActor
private func checkReassertOnRenderWhileVisible() async {
    let panel = liveBox()
    let before = panel.captureExclusionReassertCount
    panel.render(["A new response."], perLineSeconds: 0)
    #expect(await waitUntil { panel.entryCount == 1 }, "the response should be logged")
    #expect(panel.captureExclusionReassertCount > before, "a render while visible must re-assert capture exclusion")
    #expect(panel.currentSharingType == .none)
}

// A response arriving during the Settings preview is stored but stays hidden behind the sample; closing
// the preview reveals it. Guards the `guard !isPreviewing` branch in append() and the restore in
// showAppearancePreview(false).
@MainActor
private func checkAppendDuringPreview() async {
    let panel = OverlayBoxPanel()
    panel.showAppearancePreview(true)
    panel.render(["Mid-preview response."], perLineSeconds: 0)
    #expect(await waitUntil { panel.entryCount == 1 }, "the response is logged even during preview")
    #expect(panel.currentText.contains("Ask about the time complexity"), "preview still shows the sample…")
    #expect(!panel.currentText.contains("Mid-preview response."), "…not the response that arrived during it")
    panel.showAppearancePreview(false)
    #expect(panel.currentText.contains("Mid-preview response."), "closing the preview reveals the mid-preview response")
    #expect(!panel.currentText.contains("Ask about the time complexity"), "the sample is gone after preview closes")
}

// The clear button exists only when there is something to erase, so an empty box carries no dead
// control. It erases through the same `clear()` the panel already exposed.
@MainActor
private func checkClearButtonFollowsTheLog() async {
    let panel = liveBox()
    #expect(!panel.isClearButtonVisible, "an empty box offers nothing to erase")
    panel.render(["A new response."], perLineSeconds: 0)
    #expect(await waitUntil { panel.isClearButtonVisible }, "the first tip must reveal the clear button")

    panel.clickClearButton()
    #expect(panel.entryCount == 0, "the header button must erase the log")
    #expect(panel.currentText.isEmpty, "an erased box is blank, with no placeholder")
    #expect(!panel.isClearButtonVisible, "an erased box offers nothing to erase again")
}

// The preview renders sample entries, so the header offers a clear button over content that is not
// the real log. Pressing it used to empty `entries` and return before re-rendering, so the sample
// stayed on screen and the session's history was gone the moment the preview closed: destructive,
// silent, and one click away.
@MainActor
private func checkPreviewClearLeavesTheLogAlone() async {
    let panel = liveBox()
    panel.render(["A real tip."], perLineSeconds: 0)
    #expect(await waitUntil { panel.entryCount == 1 }, "the tip should be logged")
    panel.setSessionLive(false)          // the preview only opens while stopped

    panel.showAppearancePreview(true)
    panel.clickClearButton()             // hidden by the preview, and inert even if reached
    panel.showAppearancePreview(false)

    #expect(panel.entryCount == 1, "the preview's clear button must not erase the session's log")
    #expect(panel.currentText.contains("A real tip."))
}

// Each spoken tip becomes one entry, its lines joined into a single paragraph, newest last.
@MainActor
private func checkAppendsEntries() async {
    let panel = OverlayBoxPanel()
    panel.render(["Ask about the time complexity."], perLineSeconds: 0)
    panel.render(["Mention", "the edge case."], perLineSeconds: 0)

    #expect(await waitUntil { panel.entryCount == 2 }, "both tips should be logged")
    #expect(panel.currentText.contains("Ask about the time complexity."))
    #expect(panel.currentText.contains("Mention the edge case."), "a tip's lines join into one entry")
}

// Empty / whitespace-only tips must not add blank entries — matches the overlay's empty-line guard.
@MainActor
private func checkDropsEmptyTips() async {
    let panel = OverlayBoxPanel()
    panel.render([], perLineSeconds: 0)
    panel.render(["   ", "", "\n\t"], perLineSeconds: 0)
    try? await Task.sleep(nanoseconds: 200_000_000)   // give any erroneous append a chance to run
    #expect(panel.entryCount == 0, "empty/whitespace-only tips must not be logged")
}
