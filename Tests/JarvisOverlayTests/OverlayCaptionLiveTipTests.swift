import Testing
import AppKit
import JarvisCore
@testable import JarvisOverlay

/// Async tests are nonisolated wrappers that `await` a `@MainActor` helper: `@MainActor async
/// @Test` miscompiles on the bundled swift-testing toolchain.
// Serialized: concurrent captions make each other's main-actor timer observations
// scheduler-dependent.
@Suite(.serialized) struct OverlayCaptionLiveTipTests {
    @Test func line1StreamsThenPlaysWhenItCloses() async { await checkLine1Streams() }
    @Test func aSlowLine2HoldsTheGapUntilItCloses() async { await checkWaitingState() }
    @Test func deliverFinalizesTheLiveTipWithoutASecondTip() async { await checkDeliverFinalizes() }
    @Test func nilWithdrawsTheLiveTipAndHidesThePanel() async { await checkWithdraw() }
    @Test func aLiveTipWaitsBehindThePlayingTip() async { await checkQueuedLiveTip() }

    @MainActor @Test
    func nothingShowsBeforeTheFirstCharacter() {
        let panel = OverlayCaptionPanel()
        panel.showReplyProgress(progress(open: ""), perLineSeconds: [])
        panel.showReplyProgress(progress(open: "   "), perLineSeconds: [])
        #expect(!panel.isPanelVisible)
        #expect(!panel.isShowingLiveTip)
    }

    @MainActor @Test
    func aDisabledCaptionIgnoresProgress() {
        let panel = OverlayCaptionPanel()
        panel.setEnabled(false)
        panel.showReplyProgress(progress(open: "Sort"), perLineSeconds: [])
        #expect(!panel.isPanelVisible)
        panel.showReplyProgress(nil, perLineSeconds: [])
        #expect(!panel.isPanelVisible)
    }
}

private func progress(closed: [String] = [], open: String? = nil, complete: Bool = false) -> BrainReplyProgress {
    BrainReplyProgress(closedLines: closed, openLine: open, linesComplete: complete, detailMarkdown: nil)
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
private func checkLine1Streams() async {
    let panel = OverlayCaptionPanel()
    panel.interLineGapSeconds = 0
    let before = panel.captureExclusionReassertCount

    panel.showReplyProgress(progress(open: "Sort"), perLineSeconds: [])
    #expect(panel.isPanelVisible, "the first character shows the panel")
    #expect(panel.currentText == "Sort")
    #expect(panel.captureExclusionReassertCount > before, "a live tip goes through the annotated show path")
    #expect(panel.isShowingLiveTip)

    panel.showReplyProgress(progress(open: "Sort by start"), perLineSeconds: [])
    #expect(panel.currentText == "Sort by start", "the open line grows in place")

    // Line 1 closes with a long timer, so it stays up while line 2 is still being written.
    panel.showReplyProgress(progress(closed: ["Sort by start."], open: "Then"), perLineSeconds: [5])
    #expect(panel.currentText == "Sort by start.")
    panel.showReplyProgress(progress(closed: ["Sort by start."], open: "Then merge"), perLineSeconds: [5])
    #expect(panel.currentText == "Sort by start.", "later lines never stream character by character")
    panel.showReplyProgress(nil, perLineSeconds: [])
}

@MainActor
private func checkWaitingState() async {
    let panel = OverlayCaptionPanel()
    panel.interLineGapSeconds = 0

    panel.showReplyProgress(progress(closed: ["First."]), perLineSeconds: [0.3])
    #expect(panel.currentText == "First.")
    #expect(await waitUntil { panel.currentText == "" }, "line 1's timer ran out")
    #expect(panel.isPanelVisible, "a live tip holds the gap instead of hiding")
    #expect(panel.isShowingLiveTip)

    panel.showReplyProgress(progress(closed: ["First.", "Second."], open: nil), perLineSeconds: [0.3, 5])
    // Synchronous when the gap has already ended, one gap tick later otherwise.
    #expect(await waitUntil { panel.currentText == "Second." }, "the closed line shows as soon as it arrives")
    panel.showReplyProgress(nil, perLineSeconds: [])
}

@MainActor
private func checkDeliverFinalizes() async {
    let panel = OverlayCaptionPanel()
    panel.interLineGapSeconds = 0

    panel.showReplyProgress(progress(closed: ["First."]), perLineSeconds: [0.3])
    #expect(await waitUntil { panel.currentText == "" }, "waiting for line 2")
    _ = panel.deliver(["First.", "Second."], perLineSeconds: [0.3, 0.3], detail: nil)
    #expect(!panel.isShowingLiveTip)
    #expect(await waitUntil { panel.currentText == "Second." }, "deliver hands the waiting tip its remaining line")
    #expect(await waitUntil { !panel.isPanelVisible }, "the finalized tip runs out and hides")

    panel.render(["probe"], perLineSeconds: 0.3)
    #expect(await waitUntil { panel.currentText == "probe" }, "no second copy of the delivered tip was queued ahead")
}

@MainActor
private func checkWithdraw() async {
    let panel = OverlayCaptionPanel()
    panel.showReplyProgress(progress(open: "Half a"), perLineSeconds: [])
    #expect(panel.isPanelVisible)
    panel.showReplyProgress(nil, perLineSeconds: [])
    #expect(!panel.isPanelVisible, "a withdrawn live tip hides the panel")
    #expect(!panel.isShowingLiveTip)

    panel.showReplyProgress(progress(closed: ["Kept."]), perLineSeconds: [5])
    #expect(panel.currentText == "Kept.", "a later reply starts a fresh live tip")
    panel.showReplyProgress(nil, perLineSeconds: [])
}

@MainActor
private func checkQueuedLiveTip() async {
    let panel = OverlayCaptionPanel()
    panel.interLineGapSeconds = 0
    panel.render(["Earlier tip."], perLineSeconds: 0.4)
    #expect(await waitUntil { panel.currentText == "Earlier tip." })

    panel.showReplyProgress(progress(open: "Next"), perLineSeconds: [])
    #expect(panel.currentText == "Earlier tip.", "a live tip never interrupts the tip on screen")
    panel.showReplyProgress(progress(closed: ["Next one."]), perLineSeconds: [5])
    #expect(await waitUntil(timeout: 3) { panel.currentText == "Next one." }, "the queued live tip plays with its closed line")
    #expect(panel.isShowingLiveTip)
    panel.showReplyProgress(nil, perLineSeconds: [])
    #expect(!panel.isPanelVisible)
}
