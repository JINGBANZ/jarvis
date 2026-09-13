import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct PinnedDiagramTests {
    @MainActor @Test func diagramStaysOutsideHistoryUntilSessionEnds() throws {
        let (panel, content) = try makePanel()
        defer { panel.setSessionLive(false) }
        #expect(image(in: content)?.image == nil)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        _ = panel.deliver(["Sketch the request path."], perLineSeconds: [2], diagram: graph, explanation: nil)
        let drawing = try #require(image(in: content))
        let original = try #require(drawing.image)
        #expect(!drawing.isHiddenOrHasHiddenAncestor)
        #expect(!panel.currentText.contains("\u{FFFC}"))
        #expect(drawing.enclosingScrollView == nil, "history scrolling cannot move the diagram")
        #expect(panel.currentSharingType == .none)
        for _ in 0..<20 {
            _ = panel.deliver(["Discuss tradeoffs."], perLineSeconds: [2], diagram: nil, explanation: nil)
        }
        #expect(drawing.image === original)
        panel.clickClearButton()
        #expect(panel.currentText.isEmpty)
        #expect(drawing.image === original)
        #expect(!drawing.isHiddenOrHasHiddenAncestor)
        panel.setSessionLive(false)
        #expect(drawing.image == nil)
        #expect(!panel.isPanelVisible)
        panel.setSessionLive(true)
        #expect(drawing.image == nil)
        #expect(drawing.isHiddenOrHasHiddenAncestor)
    }

    @MainActor @Test func onlyValidRevisionsReplaceThePinnedDiagram() throws {
        let (panel, content) = try makePanel()
        defer { panel.setSessionLive(false) }
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        _ = panel.deliver(["First design."], perLineSeconds: [2], diagram: graph, explanation: nil)
        let drawing = try #require(image(in: content))
        let original = try #require(drawing.image)
        _ = panel.deliver(["Still useful text."], perLineSeconds: [2],
                          diagram: DiagramHint(mermaid: "invalid"), explanation: nil)
        #expect(drawing.image === original)
        let revision = try #require(DiagramHint(mermaid: "flowchart TD\nA[API] --> B[Cache]\nB --> C[Database]"))
        _ = panel.deliver(["Add a cache."], perLineSeconds: [2], diagram: revision, explanation: nil)
        #expect(drawing.image != nil)
        #expect(drawing.image !== original)
    }

    @MainActor @Test func diagramToggleCollapseAndBoxToggleRetainTheLatestGraph() throws {
        let (panel, content) = try makePanel()
        defer { panel.setSessionLive(false) }
        panel.setDiagramsEnabled(false)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        _ = panel.deliver(["First design."], perLineSeconds: [2], diagram: graph, explanation: nil)
        let drawing = try #require(image(in: content))
        #expect(drawing.isHiddenOrHasHiddenAncestor)
        panel.setDiagramsEnabled(true)
        #expect(!drawing.isHiddenOrHasHiddenAncestor)
        #expect(drawing.image != nil)
        panel.clickCollapseButton()
        #expect(drawing.isHiddenOrHasHiddenAncestor)
        panel.clickCollapseButton()
        #expect(!drawing.isHiddenOrHasHiddenAncestor)
        #expect(drawing.image != nil)
        panel.setEnabled(false)
        #expect(!panel.isPanelVisible)
        panel.setEnabled(true)
        #expect(panel.isPanelVisible)
        #expect(drawing.image != nil)
        panel.showAppearancePreview(true)
        #expect(drawing.image != nil, "preview cannot replace a live session")
        panel.setSessionLive(false)
        #expect(drawing.image == nil, "stopped preview cannot show a session graph")
        panel.showAppearancePreview(false)
        panel.setSessionLive(true)
        #expect(drawing.image == nil)
    }

    @MainActor @Test func emptyCodeAreaYieldsToDiagramAtMinimumPanelSize() throws {
        let (panel, content) = try makePanel()
        defer { panel.setSessionLive(false) }
        panel.setContentSize(panel.minimumContentSize)
        panel.setCodeEnabled(true)
        #expect(panel.currentCodeHeight > 0)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        _ = panel.deliver(["First design."], perLineSeconds: [2], diagram: graph, explanation: nil)
        let drawing = try #require(image(in: content))
        #expect(drawing.bounds.height > 0)
        #expect(drawing.image != nil)
        #expect(panel.currentCodeHeight == 0, "an empty code placeholder cannot crowd out the design")
        panel.setDiagramsEnabled(false)
        #expect(panel.currentCodeHeight > 0, "hiding diagrams restores the enabled code area")
    }

    @MainActor @Test func crampedDiagramYieldsSpaceToHistoryAndReturnsAfterResize() throws {
        let (panel, content) = try makePanel()
        defer { panel.setSessionLive(false) }
        panel.setCodeEnabled(true)
        let snippet = try #require(CodeSnippet(language: "python", placement: "Start", code: "seen = {}"))
        #expect(panel.deliverCodeSnippet(snippet) == snippet)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        _ = panel.deliver(["First design."], perLineSeconds: [2], diagram: graph, explanation: nil)
        let diagramView = try #require(content.subviews.compactMap { $0 as? DiagramHintView }.first)
        let history = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        panel.setContentSize(NSSize(width: 520, height: 190))
        #expect(diagramView.frame.height == 0, "chrome without a drawable graph must not take history space")
        #expect(history.frame.minY == panel.currentCodeHeight)
        panel.setContentSize(NSSize(width: 520, height: 440))
        #expect(diagramView.frame.height > 40)
        #expect(image(in: diagramView)?.image != nil, "the retained diagram returns when there is room")
    }

    @MainActor @Test func stoppedDeliveryCannotRepopulateNextInterview() throws {
        let (panel, content) = try makePanel()
        panel.setSessionLive(false)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        _ = panel.deliver(["Late result."], perLineSeconds: [2], diagram: graph, explanation: nil)
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        #expect(image(in: content)?.image == nil)
    }

    @MainActor @Test func pinnedDiagramResizesProportionallyAndLeavesHistorySpace() throws {
        let (panel, content) = try makePanel()
        defer { panel.setSessionLive(false) }
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[API]\nB --> C[Database]"))
        _ = panel.deliver(["Sketch this path."], perLineSeconds: [2], diagram: graph, explanation: nil)
        let drawing = try #require(image(in: content))
        let before = try #require(drawing.image).size
        panel.setContentSize(NSSize(width: 260, height: 220))
        let after = try #require(drawing.image).size
        #expect(after.width < before.width && after.height < before.height)
        #expect(abs(after.width / after.height - before.width / before.height) < 0.01)
        #expect(after.width <= drawing.bounds.width && after.height <= drawing.bounds.height)
        let history = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(history.frame.height >= 44)
        let drawingFrame = drawing.convert(drawing.bounds, to: content)
        #expect(drawingFrame.maxY <= history.frame.minY)
    }

    @MainActor private func makePanel() throws -> (OverlayBoxPanel, NSView) {
        let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        let window = try #require(NSApplication.shared.windows.first { !windows.contains($0.windowNumber) })
        panel.setEnabled(true)
        panel.setSessionLive(true)
        return (panel, try #require(window.contentView))
    }

    @MainActor private func image(in view: NSView) -> NSImageView? {
        (view as? NSImageView) ?? view.subviews.lazy.compactMap { image(in: $0) }.first
    }
}
