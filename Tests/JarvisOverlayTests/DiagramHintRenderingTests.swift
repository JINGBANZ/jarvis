import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@Suite struct DiagramHintRenderingTests {
    @MainActor @Test func denseGraphCompactsBeforeScrollingAndStopsAtReadableSize() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\n" + (0..<7).map {
            "N\($0)[Step \($0)] -->|Continue| N\($0 + 1)[Step \($0 + 1)]"
        }.joined(separator: "\n")))
        let roomy = DiagramHintImage.render(graph, fitting: CGSize(width: 320, height: 700))
        let compact = DiagramHintImage.render(graph, fitting: CGSize(width: 320, height: 600))
        let tiny = DiagramHintImage.render(graph, fitting: CGSize(width: 320, height: 40))
        #expect(compact.size.height < roomy.size.height)
        #expect(tiny.size.height == compact.size.height, "once at the minimum, scroll instead of shrinking further")
        #expect(tiny.size.height > 400, "all eight nodes and labels remain legible rather than fitting forty pixels")
        #expect(tiny.size.width <= 320)
        let minimum = DiagramHintImage.fittedDrawing(graph, fitting: CGSize(width: 320, height: 40))
        #expect(minimum.nodeFontSize >= 13)
        #expect(minimum.edgeFontSize >= 11)
        let spacious = DiagramHintImage.fittedDrawing(graph, fitting: CGSize(width: 520, height: 1000))
        #expect(spacious.nodeFontSize == 15, "a graph that fits retains normal text size")
    }

    @MainActor @Test func narrowFocusedGraphRendersThreeConnectedBranches() throws {
        let graph = try #require(DiagramHint(mermaid: """
        flowchart TD
        A[Client] -->|Request links| B[Package service]
        A -->|Fetch files| C[Edge cache]
        B -->|Check rights| D[Rights service]
        B -->|Read manifest| E[Version metadata]
        C -->|Cache miss| F[File storage]
        """))
        let image = DiagramHintImage.render(graph, fitting: CGSize(width: 320, height: 350))
        #expect(image.size.width <= 320)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        var maximumBoxes = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            var run = 0, boxes = 0
            for x in stride(from: 0, through: bitmap.pixelsWide, by: 4) {
                let color = x < bitmap.pixelsWide ? bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) : nil
                let fill = color.map {
                    $0.alphaComponent > 0.9 && $0.redComponent < 0.3
                        && $0.blueComponent > $0.redComponent + 0.08
                        && $0.blueComponent < 0.5
                } ?? false
                if fill { run += 4 } else {
                    if CGFloat(run) >= 60 * scale { boxes += 1 }
                    run = 0
                }
            }
            maximumBoxes = max(maximumBoxes, boxes)
        }
        #expect(maximumBoxes == 3, "the renderer retains the three leaf boxes on one row")
    }

    @MainActor @Test func coloredDashedArrowsRenderTheirStyle() throws {
        func coloredPixels(_ arrow: String) throws -> Int {
            let graph = try #require(DiagramHint(mermaid:
                "flowchart TD\nA[API] \(arrow) B[Queue]\nlinkStyle 0 stroke:#EAB308,stroke-width:3px"))
            let image = DiagramHintImage.render(graph, fitting: CGSize(width: 200, height: 1))
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.redComponent > 0.7 && color.greenComponent > 0.4 && color.blueComponent < 0.2 {
                        count += 1
                    }
                }
            }
            return count
        }
        let solid = try coloredPixels("-->")
        let dashed = try coloredPixels("-.->")
        #expect(solid > 100)
        #expect(dashed > 40)
        #expect(dashed < solid, "dashed strokes leave visible gaps while preserving colored arrowheads")
    }

    @MainActor @Test func asyncDiagramDeliveryDrawsInsideThePrivatePanel() async throws {
        let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel()
        let window = try #require(NSApplication.shared.windows.first { !windows.contains($0.windowNumber) })
        panel.setSessionLive(true)
        let detail = try #require(ReplyDetail(markdown:
            "A first sketch.\n\n```mermaid\nflowchart LR\nA[Client] --> B[API]\n```"))
        panel.render(["Sketch the request path."], detail: detail)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.currentText.contains("Sketch the request path."))
        #expect(!panel.currentText.contains("\u{FFFC}"), "the graph is drawn in the detail box, not in the hints")
        let content = try #require(window.contentView)
        let drawing = try #require(findImage(content))
        #expect(drawing.image != nil)
        #expect(panel.currentSharingType == .none)

        panel.setSessionLive(false)
        #expect(panel.currentDetail == nil, "Stop resets the detail box")
        panel.clear()
        #expect(panel.currentText.isEmpty)
        #expect(!panel.isPanelVisible)
    }

    @MainActor @Test func longGraphPreservesReadableScaleInSmallViewports() throws {
        let source = "flowchart LR\n" + (0..<7).map { "N\($0)[Service \($0)] --> N\($0 + 1)[Service \($0 + 1)]" }.joined(separator: "\n")
        let graph = try #require(DiagramHint(mermaid: source))
        let large = DiagramHintImage.render(graph, fitting: NSSize(width: 600, height: 300))
        let small = DiagramHintImage.render(graph, fitting: NSSize(width: 300, height: 150))
        #expect(large.size.width <= 600)
        #expect(small.size.width <= 300)
        #expect(small.size.height > 150, "long chains scroll vertically at readable font sizes")
        #expect(large.size.height == small.size.height, "both narrow viewports keep the same readable vertical flow")
        let short = DiagramHintImage.render(graph, fitting: NSSize(width: 600, height: 20))
        #expect(short.size.height <= large.size.height)
        #expect(short.size.height > 150, "limited height still scrolls instead of shrinking labels")
    }

    @MainActor @Test func laterBranchDoesNotDrawThroughAnEarlierLabel() throws {
        let graph = try #require(DiagramHint(mermaid: """
            flowchart LR
            A[Request] --> B[Gather]
            B --> C[Validate]
            C -->|AA AA| D[Draft]
            C -->|hold| E[Review]
            D --> F[Verify]
            E --> F
            F --> G[Save]
            G --> H[Notify]
            """))
        let available = CGSize(width: 520, height: 200)
        let layout = DiagramHintImage.fittedDrawing(graph, fitting: available).layout
        let routes = layout.routes
        let center = routes[2].labelCenter
        let image = DiagramHintImage.render(graph, fitting: available)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let scale = CGFloat(bitmap.pixelsWide) / layout.size.width
        let color = try #require(bitmap.colorAt(x: Int(center.x * scale), y: Int(center.y * scale))?
            .usingColorSpace(.deviceRGB))
        #expect(color.redComponent < 0.2, "the space between AA and AA shows label background, not an edge")
    }

    @MainActor @Test func anUnsupportedGraphKeepsTheRestOfTheDocument() async throws {
        let panel = OverlayBoxPanel()
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        let detail = try #require(ReplyDetail(markdown:
            "Keep the text hint.\n\n```mermaid\nsequenceDiagram\nA->>B: write\n```"))
        #expect(detail.diagram == nil)
        #expect(detail.dropped.count == 1)
        panel.render(["Keep the text hint."], detail: detail)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.currentText.contains("Keep the text hint."))
        #expect(!panel.showsDiagram)
        #expect(panel.currentDetailProseText.contains("Keep the text hint."))
        #expect(panel.entryCount == 1)
    }

    @MainActor @Test func resizingPanelKeepsItsDiagramReadableBelowNativeSize() async throws {
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 520, height: 440))
        let window = try #require(NSApplication.shared.windows.first { !previousWindows.contains($0.windowNumber) })
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        let detail = try #require(ReplyDetail(markdown:
            "```mermaid\nflowchart TD\nA[Client] --> B[API]\nB --> C[Database]\n```"))
        panel.render(["Sketch this path."], detail: detail)
        for _ in 0..<100 where panel.entryCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let content = try #require(window.contentView)
        let drawing = try #require(findImage(content))
        func imageSize() throws -> NSSize { try #require(drawing.image).size }
        let before = try imageSize()
        panel.setContentSize(NSSize(width: 260, height: 220))
        let after = try imageSize()
        #expect(after.height <= drawing.bounds.height, "the graph fits inside the detail box")
        #expect(after.width <= 232, "resizing reflows within the panel padding")
        #expect(after.height >= 196, "three nodes retain their native 36-point boxes and gaps")
        #expect(after.width <= before.width && after.height <= before.height)
    }

    @MainActor @Test func aVerticalDragGrowsATallGraph() throws {
        let (panel, drawing) = try makeDiagramPanel(
            "flowchart TD\nA[Client] --> B[API]\nB --> C[Database]",
            size: NSSize(width: 420, height: 380))
        defer { panel.setSessionLive(false) }
        let start = try #require(drawing.image).size

        panel.setContentSize(NSSize(width: 420, height: 900))
        let taller = try #require(drawing.image).size
        #expect(taller.height > start.height)
        #expect(abs(taller.width / taller.height - start.width / start.height) < 0.01)
    }

    @MainActor @Test func aHorizontalDragGrowsAWideGraph() throws {
        let (panel, drawing) = try makeDiagramPanel(
            "flowchart LR\nA[Client] --> B[API]\nB --> C[Database]",
            size: NSSize(width: 420, height: 380))
        defer { panel.setSessionLive(false) }
        let start = try #require(drawing.image).size

        panel.setContentSize(NSSize(width: 900, height: 380))
        let wider = try #require(drawing.image).size
        #expect(wider.width > start.width)
        #expect(wider.width > wider.height, "extra width permits the requested horizontal flow")
        #expect(start.height > start.width, "the narrow panel uses vertical flow")
    }

    @MainActor private func makeDiagramPanel(
        _ source: String, size: NSSize
    ) throws -> (OverlayBoxPanel, NSImageView) {
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        let panel = OverlayBoxPanel(contentSize: size)
        let window = try #require(NSApplication.shared.windows.first {
            !previousWindows.contains($0.windowNumber)
        })
        panel.setSessionLive(true)
        let detail = try #require(ReplyDetail(markdown: "```mermaid\n\(source)\n```"))
        _ = panel.deliver(["Sketch this path."], detail: detail)
        let content = try #require(window.contentView)
        return (panel, try #require(findImage(content)))
    }

    @MainActor private func findImage(_ view: NSView) -> NSImageView? {
        (view as? NSImageView) ?? view.subviews.lazy.compactMap { findImage($0) }.first
    }

    @MainActor @Test func bypassConnectionTravelsOutsideIntermediateBox() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[Cache]\nB --> C[Database]\nA --> C"))
        let image = DiagramHintImage.render(graph, fitting: NSSize(width: 500, height: 800))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let layout = DiagramHintLayout(graph, fitting: CGSize(width: 500, height: 800),
            box: CGSize(width: 144, height: 36), edgeLabel: CGSize(width: 100, height: 20), margin: 16)
        let cache = try #require(layout.frames["B"])
        let route = layout.routes[2]
        let side = try #require(route.points.map(\.x).max())
        #expect(side > cache.maxX)
        let scale = CGFloat(bitmap.pixelsWide) / layout.size.width
        #expect((bitmap.colorAt(x: Int(side * scale), y: Int(cache.midY * scale))?.alphaComponent ?? 0) > 0.5)
    }

    @MainActor @Test func wrappedBranchesKeepBothEdgeLabelsVisible() throws {
        let graph = try #require(DiagramHint(mermaid:
            "flowchart TD\nA[API] -->|read| B[Cache]\nA -->|write| C[Database]"))
        let image = DiagramHintImage.render(graph, fitting: NSSize(width: 200, height: 100))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let pixelsPerPoint = CGFloat(bitmap.pixelsWide) / image.size.width
        // Two label tracks below API, above either wrapped destination node.
        for centerY in [70.0, 98.0] {
            var whitePixels = 0
            for y in Int((centerY - 10) * pixelsPerPoint)..<Int((centerY + 10) * pixelsPerPoint) {
                for x in Int(38 * pixelsPerPoint)..<Int(138 * pixelsPerPoint) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.9 && color.redComponent > 0.9
                        && color.greenComponent > 0.9 && color.blueComponent > 0.9 {
                        whitePixels += 1
                    }
                }
            }
            #expect(whitePixels > 10, "each track contains visible label glyphs, not just its gray connector")
        }
    }

    @MainActor @Test func rendersReadableImageAndGrowsWhenSpacePermits() throws {
        let graph = try #require(DiagramHint(mermaid: "flowchart TD\nA[Client] --> B[API]\nB --> C[Database]\nB --> D[Cache]"))
        let image = DiagramHintImage.render(graph, fitting: NSSize(width: 1032, height: 1072))
        #expect(image.size.width <= 1032)
        #expect(image.size.height > 150)
        let small = DiagramHintImage.render(graph, fitting: NSSize(width: 516, height: 536))
        #expect(small.size.width <= 516)
        #expect(abs(small.size.height * 2 - image.size.height) < 0.01)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // A blank image still has dimensions, so count painted pixels.
        var painted = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { painted += 1 }
            }
        }
        #expect(painted > 100)
    }
}
