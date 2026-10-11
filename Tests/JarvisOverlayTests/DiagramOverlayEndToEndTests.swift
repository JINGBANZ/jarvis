import AppKit
import JarvisCore
import Testing
@testable import JarvisOverlay

@MainActor
@Suite(.serialized) struct DiagramOverlayEndToEndTests {
    private let source = """
    flowchart TD
    A[Client] -->|Request links| B[Package service]
    A -->|Fetch files| C[Edge cache]
    B -->|Check rights| D[Rights service]
    B -->|Read manifest| E[Version metadata]
    C -.->|Cache miss| F[File storage]
    linkStyle 4 stroke:#EAB308,stroke-width:3px
    """

    @Test func streamedDiagramStaysConnectedAndReadableThroughPanelResizes() throws {
        let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let panel = OverlayBoxPanel(contentSize: NSSize(width: 360, height: 600))
        let window = try #require(NSApp.windows.first { !previous.contains(ObjectIdentifier($0)) })
        panel.setSessionLive(true)
        defer { panel.setSessionLive(false) }
        let originalFrame = panel.currentFrame
        let hint = "Trace the download path."
        let partial = "```mermaid\n" + source
        panel.showReplyProgress(BrainReplyProgress(
            closedLines: [hint], openLine: nil, linesComplete: true, detailMarkdown: partial))
        #expect(panel.currentDetailPlaceholderText == "Drawing diagram…")
        #expect(!panel.showsDiagram)
        #expect(panel.currentFrame == originalFrame)
        let markdown = partial + "\n```"
        panel.showReplyProgress(BrainReplyProgress(
            closedLines: [hint], openLine: nil, linesComplete: true, detailMarkdown: markdown))
        #expect(panel.showsDiagram)
        #expect(panel.currentDetailPlaceholderText == nil)
        let detail = try #require(ReplyDetail(markdown: markdown))
        #expect(panel.deliver([hint], detail: detail) == detail)
        #expect(panel.entryCount == 1)
        #expect(panel.detailCount == 1)
        #expect(!panel.hasLiveEntry)
        #expect(panel.currentFrame == originalFrame)
        let graph = try #require(panel.currentDetail?.diagram)
        #expect(graph.nodes.map(\.id) == ["A", "B", "C", "D", "E", "F"])
        #expect(graph.edges.map { "\($0.from)>\($0.to)" } == ["A>B", "A>C", "B>D", "B>E", "C>F"])
        #expect(graph.edges.compactMap(\.label) ==
            ["Request links", "Fetch files", "Check rights", "Read manifest", "Cache miss"])
        #expect(graph.edges[4].dashed)
        #expect(graph.edges[4].stroke == 0xEAB308)
        #expect(graph.edges[4].strokeWidth == 3)
        let content = try #require(window.contentView)
        let images = descendants(content).compactMap { $0 as? NSImageView }
            .filter { $0.accessibilityLabel() == "Diagram" }
        let imageView = try #require(images.first)
        #expect(images.count == 1, "shared ancestors appear in one graph, never separate branch cards")
        let detailScroll = try #require(imageView.enclosingScrollView)
        let history = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(history.documentView as? NSTextView)
        var savedSizes = 0
        panel.onSizeChanged = { _, _ in savedSizes += 1 }
        var sizes: [NSSize] = []
        for size in [NSSize(width: 360, height: 600), NSSize(width: 720, height: 900),
                     NSSize(width: 360, height: 260), NSSize(width: 360, height: 220)] {
            panel.setContentSize(size)
            let frame = panel.currentFrame
            content.layoutSubtreeIfNeeded()
            let image = try #require(imageView.image)
            sizes.append(image.size)
            #expect(panel.currentFrame == frame, "diagram layout must never resize its window")
            #expect(panel.currentDetail?.diagram == graph)
            #expect(imageView.frame.size == image.size, "the image view must not downscale readable labels")
            #expect(image.size.width <= detailScroll.contentSize.width - 28 + 0.01)
            #expect(!detailScroll.hasHorizontalScroller)
            #expect(detailScroll.hasVerticalScroller)
            #expect(history.frame.height >= 44)
            #expect(!history.isHidden)
            #expect(text.string.contains(hint))
            let range = (text.string as NSString).range(of: hint)
            let manager = try #require(text.layoutManager)
            let container = try #require(text.textContainer)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let hintRect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: text.textContainerInset.width, dy: text.textContainerInset.height)
            #expect(text.visibleRect.intersects(hintRect), "the upper hint remains onscreen")
            try assertPaintedGraph(image, graph: graph, viewport: detailScroll.contentSize)
        }
        #expect(sizes[1].width > sizes[0].width, "a larger panel enlarges the diagram")
        #expect(sizes[1].height > sizes[0].height)
        #expect(sizes[2] == sizes[3], "shorter viewports scroll after reaching the readable floor")
        #expect(sizes[3].height > detailScroll.contentSize.height)
        #expect(savedSizes == 0, "content updates do not persist a phantom user resize")
        #expect(panel.currentSharingType == .none)
        #expect(!window.isKeyWindow)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func assertPaintedGraph(_ image: NSImage, graph: DiagramHint, viewport: NSSize) throws {
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let drawing = DiagramHintImage.fittedDrawing(graph, fitting:
            NSSize(width: viewport.width - 28, height: max(1, viewport.height - 14)))
        #expect(drawing.nodeFontSize >= 13)
        #expect(drawing.edgeFontSize >= 11)
        #expect(drawing.layout.frames.count == graph.nodes.count)
        #expect(drawing.layout.routes.count == graph.edges.count)
        let scale = CGFloat(bitmap.pixelsWide) / drawing.layout.size.width
        func color(_ point: CGPoint) -> NSColor? {
            let x = Int(point.x * scale), y = Int(point.y * scale)
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        }
        func glyphPixels(in rect: CGRect, yellow: Bool = false) -> Int {
            var count = 0
            for y in stride(from: rect.minY, to: rect.maxY, by: 1 / scale) {
                for x in stride(from: rect.minX, to: rect.maxX, by: 1 / scale) {
                    guard let pixel = color(CGPoint(x: x, y: y)), pixel.alphaComponent > 0.9 else { continue }
                    if yellow {
                        if pixel.redComponent > 0.7 && pixel.greenComponent > 0.4 && pixel.blueComponent < 0.2 {
                            count += 1
                        }
                    } else if pixel.redComponent > 0.9 && pixel.greenComponent > 0.9 && pixel.blueComponent > 0.9 {
                        count += 1
                    }
                }
            }
            return count
        }
        for node in graph.nodes {
            let frame = try #require(drawing.layout.frames[node.id])
            #expect(glyphPixels(in: frame.insetBy(dx: drawing.padding, dy: drawing.padding)) > 10,
                    "every delivered node label paints visible glyphs")
        }
        for (edge, route) in zip(graph.edges, drawing.layout.routes) {
            let label = CGRect(x: route.labelCenter.x - drawing.edgeLabel.width / 2,
                               y: route.labelCenter.y - drawing.edgeLabel.height / 2,
                               width: drawing.edgeLabel.width, height: drawing.edgeLabel.height)
            #expect(glyphPixels(in: label, yellow: edge.stroke != nil) > 10,
                    "edge labels retain text and color in the actual panel image")
            var painted = 0, samples = 0
            for (start, end) in zip(route.points, route.points.dropFirst()) {
                let steps = max(1, Int(hypot(end.x - start.x, end.y - start.y)))
                for step in 0...steps {
                    let fraction = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                        y: start.y + (end.y - start.y) * fraction)
                    samples += 1
                    if (color(point)?.alphaComponent ?? 0) > 0.4 { painted += 1 }
                }
            }
            #expect(Double(painted) / Double(max(1, samples)) > (edge.dashed ? 0.35 : 0.75),
                    "each connection paints along its complete route, including shared branch trunks")
        }
    }
}
