import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct ExplanationRenderingTests {
    @MainActor @Test func explanationStaysInBoxAndSurvivesPreviewUntilCleared() async throws {
        let box = OverlayBoxPanel()
        box.setSessionLive(true)
        box.setEnabled(true)
        let caption = ShortExplanationCaption()
        BroadcastOverlay([caption, box]).render(["Move the left edge."], perLineSeconds: [2],
            diagram: nil, explanation: "A window is the current range.\n\nFor abca, remove the first a.")
        for _ in 0..<100 where box.entryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(caption.lines == ["Move the left edge."])
        #expect(box.currentText.contains("A window is the current range.\n\nFor abca"))
        #expect(box.currentSharingType == .none)
        box.showAppearancePreview(true)
        box.showAppearancePreview(false)
        #expect(box.currentText.contains("For abca"))
        box.clear()
        #expect(box.currentText.isEmpty)
        box.setSessionLive(false)
        #expect(!box.isPanelVisible)
    }
}

// Synchronous delivery on the caller's thread, read immediately after BroadcastOverlay.render.
private final class ShortExplanationCaption: OverlayRendering {
    var lines: [String] = []
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) { self.lines = lines }
}
