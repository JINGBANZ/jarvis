import Testing
import AppKit
@testable import JarvisOverlay

/// Tests for the persistent response-history window: it must stay excluded from screen capture (the
/// same privacy guarantee as the overlay), accumulate each spoken tip, toggle visibility, and clear.
///
/// Like `OverlayInvisibilityTests`, the synchronous checks are `@MainActor @Test` (the async +
/// @MainActor @Test combination miscompiles on the bundled swift-testing toolchain), while anything
/// that needs `render`'s main-actor hop to run is a nonisolated `@Test` awaiting a `@MainActor` helper.
@Suite struct ResponseLogPanelTests {

    @MainActor @Test
    func excludedFromScreenCaptureAtInit() {
        let panel = ResponseLogPanel()
        #expect(panel.currentSharingType == .none)
    }

    @MainActor @Test
    func showReassertsCaptureExclusion() {
        let panel = ResponseLogPanel()
        let before = panel.captureExclusionReassertCount
        panel.show()
        #expect(panel.captureExclusionReassertCount > before, "show() must re-assert capture exclusion")
        #expect(panel.currentSharingType == .none)
        #expect(panel.isPanelVisible)
        panel.hide()
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test
    func toggleFlipsVisibilityAndReportsIt() {
        let panel = ResponseLogPanel()
        #expect(panel.toggle() == true)   // hidden → shown
        #expect(panel.isPanelVisible)
        #expect(panel.toggle() == false)  // shown → hidden
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test
    func isResizableAndHonorsAResize() {
        let panel = ResponseLogPanel()
        #expect(panel.isResizable, "the box must be resizable by dragging its edges")
        panel.setContentSize(NSSize(width: 500, height: 400))
        #expect(panel.currentContentSize.width == 500)
        #expect(panel.currentContentSize.height == 400)
    }

    @MainActor @Test
    func appearanceSettersChangeOpacityAndFontSize() {
        let panel = ResponseLogPanel()
        panel.setBoxOpacity(0.5)
        panel.setBoxFontSize(22)
        #expect(abs(panel.currentBoxOpacity - 0.5) < 0.001)
        #expect(panel.currentFontPointSize == 22)
    }

    @MainActor @Test
    func previewShowsSampleThenRestoresPriorState() {
        let panel = ResponseLogPanel()
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
        let panel = ResponseLogPanel()
        panel.show()                       // user had the box open
        panel.showAppearancePreview(true)
        panel.showAppearancePreview(false)
        #expect(panel.isPanelVisible, "a box open before preview must stay open after it closes")
    }

    @MainActor @Test
    func clearEmptiesTheLog() {
        let panel = ResponseLogPanel()
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

// Each spoken tip becomes one entry, its lines joined into a single paragraph, newest last.
@MainActor
private func checkAppendsEntries() async {
    let panel = ResponseLogPanel()
    panel.render(["Ask about the time complexity."], perLineSeconds: 0)
    panel.render(["Mention", "the edge case."], perLineSeconds: 0)

    #expect(await waitUntil { panel.entryCount == 2 }, "both tips should be logged")
    #expect(panel.currentText.contains("Ask about the time complexity."))
    #expect(panel.currentText.contains("Mention the edge case."), "a tip's lines join into one entry")
}

// Empty / whitespace-only tips must not add blank entries — matches the overlay's empty-line guard.
@MainActor
private func checkDropsEmptyTips() async {
    let panel = ResponseLogPanel()
    panel.render([], perLineSeconds: 0)
    panel.render(["   ", "", "\n\t"], perLineSeconds: 0)
    try? await Task.sleep(nanoseconds: 200_000_000)   // give any erroneous append a chance to run
    #expect(panel.entryCount == 0, "empty/whitespace-only tips must not be logged")
}
