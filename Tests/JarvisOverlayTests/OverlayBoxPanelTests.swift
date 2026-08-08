import Testing
import AppKit
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
    func excludedFromScreenCaptureAtInit() {
        let panel = OverlayBoxPanel()
        #expect(panel.currentSharingType == .none)
    }

    @MainActor @Test
    func showReassertsCaptureExclusion() {
        let panel = OverlayBoxPanel()
        let before = panel.captureExclusionReassertCount
        panel.show()
        #expect(panel.captureExclusionReassertCount > before, "show() must re-assert capture exclusion")
        #expect(panel.currentSharingType == .none)
        #expect(panel.isPanelVisible)
        panel.hide()
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test
    func setEnabledShowsAndHidesTheBox() {
        let panel = OverlayBoxPanel()
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

    // Symmetric: switching the box ON during a preview must leave it shown after the tab closes.
    @MainActor @Test
    func setEnabledOnDuringPreviewShowsOnClose() {
        let panel = OverlayBoxPanel()      // starts hidden
        panel.showAppearancePreview(true)
        panel.setEnabled(true)             // user switches it on mid-preview
        panel.showAppearancePreview(false) // close the tab
        #expect(panel.isPanelVisible, "a box switched on during preview must stay shown on close")
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
        let panel = OverlayBoxPanel()
        panel.show()                       // user had the box open
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
// flip. Only show()/append-while-visible bump the counter, so an increase proves the re-assert ran.
@MainActor
private func checkReassertOnRenderWhileVisible() async {
    let panel = OverlayBoxPanel()
    panel.show()
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
