import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@MainActor
@Suite struct DiagramReadabilityTests {
    @Test func expansionFitsSmallAndOffsetDisplays() {
        let secondary = NSRect(x: -800, y: 100, width: 800, height: 600)
        let frame = OverlayBoxPanel.diagramFrame(
            from: NSRect(x: -100, y: 500, width: 520, height: 440), within: secondary)
        #expect(frame == secondary)
        let large = NSRect(x: 100, y: -1000, width: 1600, height: 900)
        let expanded = OverlayBoxPanel.diagramFrame(
            from: NSRect(x: 1600, y: -300, width: 520, height: 440), within: large)
        #expect(large.contains(expanded))
        #expect(expanded.size == NSSize(width: 960, height: 720))
    }

    @Test func crowdedDetailScrollsWithoutShrinkingDiagramLabels() throws {
        let source = "flowchart LR\n" + (0..<7).map {
            "N\($0)[Service \($0)] --> N\($0 + 1)[Service \($0 + 1)]"
        }.joined(separator: "\n")
        let detail = try #require(ReplyDetail(markdown:
            String(repeating: "Explain the request path.\n\n", count: 12)
                + "```mermaid\n\(source)\n```"))
        let view = DetailView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.show(detail, stamp: "", position: (0, 1), isHeld: false, isRolled: false, fontSize: 18)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let drawing = try #require(document.subviews.compactMap { $0 as? NSImageView }.first)
        let image = try #require(drawing.image)
        // Eight 172pt boxes, seven 100pt gaps, and two 36pt margins at readable native scale.
        #expect(image.size.width >= 2148)
        #expect(image.size.height >= 160)
        #expect(scroll.hasHorizontalScroller)
        #expect(scroll.hasVerticalScroller)
        #expect(document.frame.width >= drawing.frame.maxX)
        #expect(document.frame.height >= drawing.frame.maxY)
        #expect(document.frame.height > scroll.contentSize.height)
        #expect(view.proseText.contains("Explain the request path."))
    }

    @Test func diagramGetsMostOfThePanelByDefault() throws {
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 960, height: 720))
        panel.setEnabled(true)
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        let detail = try #require(ReplyDetail(markdown:
            "```mermaid\nflowchart TD\nA[Client] --> B[API]\nB --> C[Database]\n```"))
        _ = panel.deliver(["Sketch this path."], perLineSeconds: [2], detail: detail)
        #expect(panel.currentDetailHeight > panel.currentContentSize.height * 0.6)
        #expect(panel.currentSharingType == .none)
    }

    @Test func firstDiagramExpandsWithinTheDisplayWithoutSavingItsSize() throws {
        let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel()
        let window = try #require(NSApplication.shared.windows.first { !windows.contains($0.windowNumber) })
        panel.setEnabled(true)
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        let visible = try #require(window.screen).visibleFrame
        var savedSizes = 0
        panel.onSizeChanged = { _, _ in savedSizes += 1 }
        let detail = try #require(ReplyDetail(markdown:
            "```mermaid\nflowchart LR\nA[Client] --> B[API]\n```"))
        _ = panel.deliver(["Sketch this path."], perLineSeconds: [2], detail: detail)
        #expect(panel.currentContentSize.width >= min(960, visible.width))
        #expect(panel.currentContentSize.height >= min(720, visible.height))
        #expect(visible.contains(panel.currentFrame))
        #expect(savedSizes == 0)

        panel.setContentSize(NSSize(width: 400, height: 300))
        panel.endLiveResize()
        _ = panel.deliver(["Follow this path."], perLineSeconds: [2], detail: detail)
        #expect(panel.currentContentSize == NSSize(width: 400, height: 300))
        #expect(savedSizes == 1)
    }
}
