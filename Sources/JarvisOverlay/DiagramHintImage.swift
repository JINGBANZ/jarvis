import AppKit
import JarvisCore

@MainActor
enum DiagramHintImage {
    static func render(_ graph: DiagramHint, fitting available: NSSize) -> NSImage {
        let drawing = fittedDrawing(graph, fitting: available)
        let layout = drawing.layout
        let edgeLabel = drawing.edgeLabel
        let frames = layout.frames
        let natural = layout.size
        // The chosen typography has a hard minimum; remaining vertical overflow scrolls.
        let scale = max(1, min(max(1, available.width) / natural.width, max(1, available.height) / natural.height))
        let image = NSImage(size: NSSize(width: natural.width * scale, height: natural.height * scale))
        image.lockFocusFlipped(true)
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        for (edge, route) in zip(graph.edges, layout.routes) { drawEdge(route, edge: edge) }
        for (edge, route) in zip(graph.edges, layout.routes) {
            guard let label = edge.label else { continue }
            drawLabel(label, in: CGRect(
                x: min(max(0, route.labelCenter.x - edgeLabel.width / 2), max(0, natural.width - edgeLabel.width)),
                y: route.labelCenter.y - edgeLabel.height / 2,
                width: min(edgeLabel.width, natural.width), height: edgeLabel.height),
                fontSize: drawing.edgeFontSize, background: true, backgroundColor: labelBackground(for: edge.stroke), color: edge.stroke == nil ? .white : strokeColor(edge))
        }
        for node in graph.nodes {
            guard let frame = frames[node.id] else { continue }
            drawNode(node.label, in: frame, fontSize: drawing.nodeFontSize, padding: drawing.padding)
        }
        image.unlockFocus()
        return image
    }

    struct Drawing {
        let layout: DiagramHintLayout
        let edgeLabel: CGSize
        let nodeFontSize: CGFloat
        let edgeFontSize: CGFloat
        let padding: CGFloat
    }

    static func fittedDrawing(_ graph: DiagramHint, fitting available: CGSize) -> Drawing {
        var best = makeDrawing(graph, fitting: available, nodeFontSize: 15)
        guard graph.nodes.count >= 5 else { return best }
        for fontSize: CGFloat in [14, 13] {
            if best.layout.size.width <= available.width && best.layout.size.height <= available.height { break }
            let candidate = makeDrawing(graph, fitting: available, nodeFontSize: fontSize)
            if candidate.layout.size.height < best.layout.size.height { best = candidate }
        }
        return best
    }

    private static func makeDrawing(_ graph: DiagramHint, fitting available: CGSize,
                                    nodeFontSize: CGFloat) -> Drawing {
        let ratio = nodeFontSize / 15
        let edgeFontSize = (nodeFontSize + 9) / 2
        let padding = 8 * ratio
        let margin = min(16 * ratio, max(0, (available.width - 1) / 2))
        let width = min(144 * ratio, max(1, available.width - margin * 2))
        let nodeHeight = graph.nodes.map {
            labelHeight($0.label, width: max(1, width - padding * 2), fontSize: nodeFontSize) + padding * 2
        }.max() ?? 36 * ratio
        let box = NSSize(width: width, height: max(36 * ratio, nodeHeight))
        let edgeWidth = min(100 * ratio, max(1, available.width - padding * 2))
        let edgeHeight = graph.edges.compactMap(\.label).map {
            labelHeight($0, width: edgeWidth, fontSize: edgeFontSize)
        }.max() ?? 0
        var edgeLabel = NSSize(width: edgeWidth, height: max(20 * ratio, edgeHeight))
        var layout = DiagramHintLayout(graph, fitting: available, box: box,
                                       edgeLabel: edgeLabel, margin: margin)
        let fittedWidth = layout.frames.values.first?.width ?? box.width
        if fittedWidth < box.width {
            edgeLabel.width = min(edgeLabel.width, fittedWidth)
            edgeLabel.height = max(20 * ratio, graph.edges.compactMap(\.label).map {
                labelHeight($0, width: edgeLabel.width, fontSize: edgeFontSize)
            }.max() ?? 0)
            let fittedHeight = graph.nodes.map {
                labelHeight($0.label, width: max(1, fittedWidth - padding * 2), fontSize: nodeFontSize) + padding * 2
            }.max() ?? box.height
            layout = DiagramHintLayout(graph, fitting: available,
                box: NSSize(width: box.width, height: max(box.height, fittedHeight)),
                edgeLabel: edgeLabel, margin: margin)
        }
        return Drawing(layout: layout, edgeLabel: edgeLabel, nodeFontSize: nodeFontSize,
                       edgeFontSize: edgeFontSize, padding: padding)
    }

    private static func drawNode(_ label: String, in frame: CGRect, fontSize: CGFloat, padding: CGFloat) {
        let box = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.30, alpha: 1).setFill()
        box.fill()
        NSColor(calibratedRed: 0.4, green: 0.75, blue: 0.9, alpha: 1).setStroke()
        box.lineWidth = 1.5
        box.stroke()
        drawLabel(label, in: frame.insetBy(dx: padding, dy: padding), fontSize: fontSize, background: false)
    }

    private static func drawEdge(_ route: DiagramHintEdgeRoute, edge: DiagramHint.Edge) {
        let path = NSBezierPath()
        path.move(to: route.points[0])
        for point in route.points.dropFirst() { path.line(to: point) }
        strokeColor(edge).setStroke()
        path.lineWidth = edge.strokeWidth
        if edge.dashed { path.setLineDash([6, 4], count: 2, phase: 0) }
        path.stroke()
        let end = route.points.last!
        let previous = route.points[route.points.count - 2]
        let dx = end.x - previous.x, dy = end.y - previous.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let ux = dx / length, uy = dy / length
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: end.x - ux * 8 - uy * 5, y: end.y - uy * 8 + ux * 5))
        arrow.line(to: end)
        arrow.line(to: CGPoint(x: end.x - ux * 8 + uy * 5, y: end.y - uy * 8 - ux * 5))
        arrow.lineWidth = edge.strokeWidth
        arrow.stroke()
    }

    private static func strokeColor(_ edge: DiagramHint.Edge) -> NSColor {
        guard let rgb = edge.stroke else { return NSColor(white: 0.75, alpha: 1) }
        return NSColor(calibratedRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static func labelBackground(for stroke: UInt32?) -> NSColor {
        guard let stroke else { return NSColor(white: 0.10, alpha: 1) }
        let red = CGFloat((stroke >> 16) & 255) / 255
        let green = CGFloat((stroke >> 8) & 255) / 255
        let blue = CGFloat(stroke & 255) / 255
        let brightness = 0.299 * red + 0.587 * green + 0.114 * blue
        return NSColor(white: brightness < 0.5 ? 0.90 : 0.10, alpha: 1)
    }

    private static func drawLabel(_ label: String, in rect: NSRect, fontSize: CGFloat,
                                  background: Bool, backgroundColor: NSColor = NSColor(white: 0.10, alpha: 1),
                                  color: NSColor = .white) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let measured = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let centered = NSRect(x: rect.minX, y: rect.midY - measured.height / 2, width: rect.width, height: measured.height)
        if background {
            backgroundColor.setFill()
            NSBezierPath(roundedRect: centered, xRadius: 3, yRadius: 3).fill()
        }
        text.draw(with: centered, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func labelHeight(_ label: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return ceil((label as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                         .paragraphStyle: paragraph]).height)
    }
}
