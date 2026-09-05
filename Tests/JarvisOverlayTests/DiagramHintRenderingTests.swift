import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintRenderingTests {
    @MainActor @Test func diagramIsAnAttachmentInsideThePrivatePanel() async throws {
        let panel = OverlayBoxPanel()
        panel.setEnabled(true)
        panel.setSessionLive(true)
        let graph = try #require(DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        panel.render(["Sketch the request path."], perLineSeconds: [2], diagram: graph)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.currentText.contains("Sketch the request path."))
        #expect(panel.currentText.contains("\u{FFFC}"))
        #expect(panel.currentSharingType == .none)
        panel.showAppearancePreview(true)
        #expect(!panel.currentText.contains("\u{FFFC}"))
        panel.showAppearancePreview(false)
        #expect(panel.currentText.contains("\u{FFFC}"))
        panel.clear()
        #expect(panel.currentText.isEmpty)
        panel.setSessionLive(false)
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test func longHorizontalGraphKeepsReadableBoxesAtDefaultWidth() throws {
        let source = "flowchart LR\n" + (0..<7).map { "N\($0)[Service \($0)] --> N\($0 + 1)[Service \($0 + 1)]" }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let image = DiagramHintImage.render(graph, width: 492)
        #expect(image.size.width == 492)
        #expect(image.size.height >= 8 * 88, "long chains use vertical space instead of shrinking box labels")
    }

    @MainActor @Test func bypassConnectionTravelsOutsideIntermediateBox() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[Cache]\nB --> C[Database]\nA --> C"))
        let image = DiagramHintImage.render(graph, width: 500)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // The outside lane is 12 points from the right edge. At the image's middle row, the
        // ordinary A→B→C route and the Cache box are centered, leaving this lane transparent
        // unless the direct A→C connection is routed around Cache.
        let x = Int(488 / image.size.width * Double(bitmap.pixelsWide))
        let y = bitmap.pixelsHigh / 2
        #expect((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5)
    }

    @MainActor @Test func rendersReadableImageAndResizesToFit() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[API]\nB --> C[Database]\nB --> D[Cache]"))
        let image = DiagramHintImage.render(graph, width: 500)
        #expect(image.size.width == 500)
        #expect(image.size.height > 150)
        let small = DiagramHintImage.render(graph, width: 250)
        #expect(small.size.width == 250)
        #expect(small.size.height >= image.size.height, "narrowing wraps layers instead of shrinking labels")
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
