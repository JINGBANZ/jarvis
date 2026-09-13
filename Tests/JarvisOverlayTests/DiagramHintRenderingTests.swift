import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintRenderingTests {
    @MainActor @Test func asyncDiagramDeliveryPinsInsideThePrivatePanel() async throws {
        let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel()
        let window = try #require(NSApplication.shared.windows.first { !windows.contains($0.windowNumber) })
        panel.setEnabled(true)
        panel.setSessionLive(true)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        panel.render(["Sketch the request path."], perLineSeconds: [2], diagram: graph)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.currentText.contains("Sketch the request path."))
        #expect(!panel.currentText.contains("\u{FFFC}"))
        let content = try #require(window.contentView)
        let drawing = try #require(findImage(content))
        #expect(drawing.image != nil)
        #expect(panel.currentSharingType == .none)

        // The Settings sample only stands in while stopped: during a session the box is already on
        // screen carrying the real log, which is a better preview than sample text.
        panel.setSessionLive(false)
        panel.showAppearancePreview(true)
        #expect(drawing.image == nil, "Stop removes the session reference before preview")
        panel.showAppearancePreview(false)
        #expect(drawing.image == nil, "closing preview cannot restore an ended session graph")

        panel.clear()
        #expect(panel.currentText.isEmpty)
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test func longGraphScalesProportionallyWithinBothWindowDimensions() throws {
        let source = "flowchart LR\n" + (0..<7).map { "N\($0)[Service \($0)] --> N\($0 + 1)[Service \($0 + 1)]" }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let large = DiagramHintImage.render(graph, fitting: NSSize(width: 600, height: 300))
        let small = DiagramHintImage.render(graph, fitting: NSSize(width: 300, height: 150))
        #expect(large.size.width <= 600 && large.size.height <= 300)
        #expect(abs(small.size.width * 2 - large.size.width) < 0.01)
        #expect(abs(small.size.height * 2 - large.size.height) < 0.01)
        #expect(large.size.width > large.size.height, "resizing preserves the LR layout")
        let short = DiagramHintImage.render(graph, fitting: NSSize(width: 600, height: 20))
        #expect(short.size.height <= 20)
        #expect(abs(short.size.width / short.size.height - large.size.width / large.size.height) < 0.01)
    }

    @MainActor @Test func togglingDiagramsPreservesTextAndRestoresHiddenGraphs() async throws {
        let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel()
        let window = try #require(NSApplication.shared.windows.first { !windows.contains($0.windowNumber) })
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        panel.setEnabled(true)
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        panel.setDiagramsEnabled(false)
        panel.render(["Keep the text hint."], perLineSeconds: [2], diagram: graph)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.currentText.contains("Keep the text hint."))
        #expect(!panel.currentText.contains("\u{FFFC}"))
        let content = try #require(window.contentView)
        let drawing = try #require(findImage(content))
        #expect(drawing.isHiddenOrHasHiddenAncestor)
        panel.setDiagramsEnabled(true)
        #expect(drawing.image != nil)
        #expect(!drawing.isHiddenOrHasHiddenAncestor)
        panel.setDiagramsEnabled(false)
        #expect(drawing.isHiddenOrHasHiddenAncestor)
        #expect(panel.entryCount == 1)
        #expect(panel.currentText.contains("Keep the text hint."))
    }

    @MainActor @Test func resizingPanelImmediatelyResizesItsPinnedDiagram() async throws {
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        let window = try #require(NSApplication.shared.windows.first { !previousWindows.contains($0.windowNumber) })
        panel.setEnabled(true)
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[API]\nB --> C[Database]"))
        panel.render(["Sketch this path."], perLineSeconds: [2], diagram: graph)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let content = try #require(window.contentView)
        let drawing = try #require(findImage(content))
        func imageSize() throws -> NSSize { try #require(drawing.image).size }
        let before = try imageSize()
        panel.setContentSize(NSSize(width: 260, height: 220))
        let after = try imageSize()
        #expect(after.height <= drawing.bounds.height, "graph fits within its pinned area")
        #expect(after.width < before.width && after.height < before.height)
        #expect(abs(after.width / after.height - before.width / before.height) < 0.01)
    }

    @MainActor private func findImage(_ view: NSView) -> NSImageView? {
        (view as? NSImageView) ?? view.subviews.lazy.compactMap { findImage($0) }.first
    }

    @MainActor @Test func bypassConnectionTravelsOutsideIntermediateBox() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[Cache]\nB --> C[Database]\nA --> C"))
        let image = DiagramHintImage.render(graph, fitting: NSSize(width: 500, height: 800))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // The outside lane is 12 points from the right edge of the 244-point natural layout. At the image's middle row, the
        // ordinary A→B→C route and the Cache box are centered, leaving this lane transparent
        // unless the direct A→C connection is routed around Cache.
        let x = Int((1 - 12.0 / 244.0) * Double(bitmap.pixelsWide))
        let y = bitmap.pixelsHigh / 2
        #expect((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5)
    }

    @MainActor @Test func rendersReadableImageAndResizesToFit() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[API]\nB --> C[Database]\nB --> D[Cache]"))
        let image = DiagramHintImage.render(graph, fitting: NSSize(width: 500, height: 800))
        #expect(image.size.width <= 500)
        #expect(image.size.height > 150)
        let small = DiagramHintImage.render(graph, fitting: NSSize(width: 250, height: 400))
        #expect(small.size.width <= 250)
        #expect(abs(small.size.height * 2 - image.size.height) < 0.01)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // An empty/transparent attachment would still have dimensions and an object marker.
        var painted = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { painted += 1 }
            }
        }
        #expect(painted > 100)
    }
}
