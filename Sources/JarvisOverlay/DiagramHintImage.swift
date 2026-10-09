import AppKit
import JarvisCore

@MainActor
enum DiagramHintImage {
    static func render(_ graph: DiagramHint, fitting available: NSSize) -> NSImage {
        let margin = min(16, max(0, (available.width - 1) / 2))
        let width = min(144, max(1, available.width - margin * 2))
        let nodeHeight = graph.nodes.map {
            labelHeight($0.label, width: max(1, width - 16), fontSize: 15) + 16
        }.max() ?? 36
        let box = NSSize(width: width, height: max(36, nodeHeight))
        let edgeWidth = min(100, max(1, available.width - 16))
        let edgeHeight = graph.edges.compactMap(\.label).map {
            labelHeight($0, width: edgeWidth, fontSize: 12)
        }.max() ?? 0
        let edgeLabel = NSSize(width: edgeWidth, height: max(20, edgeHeight))
        var layout = DiagramHintLayout(graph, fitting: available, box: box,
                                       edgeLabel: edgeLabel, margin: margin)
        let fittedWidth = layout.frames.values.first?.width ?? box.width
        if fittedWidth < box.width {
            let fittedHeight = graph.nodes.map {
                labelHeight($0.label, width: max(1, fittedWidth - 16), fontSize: 15) + 16
            }.max() ?? box.height
            layout = DiagramHintLayout(graph, fitting: available,
                box: NSSize(width: box.width, height: max(box.height, fittedHeight)),
                edgeLabel: edgeLabel, margin: margin)
        }
        let frames = layout.frames
        let natural = layout.size
        // Layout fits the width at native font sizes; only vertical overflow scrolls.
        let scale = max(1, min(max(1, available.width) / natural.width, max(1, available.height) / natural.height))
        let image = NSImage(size: NSSize(width: natural.width * scale, height: natural.height * scale))
        image.lockFocusFlipped(true)
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        for route in layout.routes { drawEdge(route) }
        for (edge, route) in zip(graph.edges, layout.routes) {
            guard let label = edge.label else { continue }
            drawLabel(label, in: CGRect(
                x: min(max(0, route.labelCenter.x - edgeLabel.width / 2), max(0, natural.width - edgeLabel.width)),
                y: route.labelCenter.y - edgeLabel.height / 2,
                width: min(edgeLabel.width, natural.width), height: edgeLabel.height),
                fontSize: 12, background: true)
        }
        for node in graph.nodes {
            guard let frame = frames[node.id] else { continue }
            let box = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
            NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.30, alpha: 1).setFill()
            box.fill()
            NSColor(calibratedRed: 0.4, green: 0.75, blue: 0.9, alpha: 1).setStroke()
            box.lineWidth = 1.5
            box.stroke()
            drawLabel(node.label, in: frame.insetBy(dx: 8, dy: 8), fontSize: 15, background: false)
        }
        image.unlockFocus()
        return image
    }

    private static func drawEdge(_ route: DiagramHintEdgeRoute) {
        let path = NSBezierPath()
        path.move(to: route.points[0])
        for point in route.points.dropFirst() { path.line(to: point) }
        NSColor(white: 0.75, alpha: 1).setStroke()
        path.lineWidth = 2
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
        arrow.lineWidth = 2
        arrow.stroke()
    }

    private static func drawLabel(_ label: String, in rect: NSRect, fontSize: CGFloat, background: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let measured = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let centered = NSRect(x: rect.minX, y: rect.midY - measured.height / 2, width: rect.width, height: measured.height)
        if background {
            NSColor(white: 0.10, alpha: 1).setFill()
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
