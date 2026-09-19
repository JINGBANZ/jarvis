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
        let layout = DiagramHintLayout(graph, fitting: available, box: box,
                                       edgeLabel: edgeLabel, margin: margin)
        let frames = layout.frames
        let natural = layout.size
        let horizontal = layout.horizontal
        // Layout fits the width at native font sizes; only vertical overflow scrolls.
        let scale = max(1, min(max(1, available.width) / natural.width, max(1, available.height) / natural.height))
        let image = NSImage(size: NSSize(width: natural.width * scale, height: natural.height * scale))
        image.lockFocusFlipped(true)
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        for (index, edge) in graph.edges.enumerated() {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let forward = horizontal ? to.minX > from.minX : to.minY > from.minY
            let start = horizontal
                ? NSPoint(x: from.maxX, y: from.midY) : NSPoint(x: from.midX, y: from.maxY)
            let end = horizontal
                ? NSPoint(x: to.minX, y: to.midY) : NSPoint(x: to.midX, y: to.minY)
            let path = NSBezierPath()
            path.move(to: start)
            let labelPoint: NSPoint
            let interveningBox = frames.contains { id, frame in
                guard id != edge.from, id != edge.to else { return false }
                return horizontal
                    ? frame.minX > from.minX && frame.minX < to.minX
                    : frame.minY > from.minY && frame.minY < to.minY
            }
            let labelIndex = graph.edges.prefix(index).filter {
                $0.from == edge.from && $0.label != nil
            }.count
            let labelExtent = horizontal ? edgeLabel.width : edgeLabel.height
            let offset = edge.label == nil ? 8 : 4 + (CGFloat(labelIndex) + 0.5) * (labelExtent + 8)
            let track = (horizontal ? start.x : start.y) + offset
            labelPoint = horizontal ? NSPoint(x: track, y: start.y) : NSPoint(x: start.x, y: track)
            if forward && !interveningBox {
                path.line(to: horizontal ? NSPoint(x: track, y: start.y) : NSPoint(x: start.x, y: track))
                path.line(to: horizontal ? NSPoint(x: track, y: end.y) : NSPoint(x: end.x, y: track))
            } else if horizontal {
                let lane = natural.height - margin / 2
                path.line(to: NSPoint(x: track, y: start.y))
                path.line(to: NSPoint(x: track, y: lane))
                path.line(to: NSPoint(x: end.x - 8, y: lane))
                path.line(to: NSPoint(x: end.x - 8, y: end.y))
            } else {
                let lane = natural.width - margin / 2
                path.line(to: NSPoint(x: start.x, y: track))
                path.line(to: NSPoint(x: lane, y: track))
                path.line(to: NSPoint(x: lane, y: end.y - 8))
                path.line(to: NSPoint(x: end.x, y: end.y - 8))
            }
            path.line(to: end)
            NSColor(white: 0.75, alpha: 1).setStroke()
            path.lineWidth = 2
            path.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: horizontal ? NSPoint(x: end.x - 8, y: end.y - 5) : NSPoint(x: end.x - 5, y: end.y - 8))
            arrow.line(to: end)
            arrow.line(to: horizontal ? NSPoint(x: end.x - 8, y: end.y + 5) : NSPoint(x: end.x + 5, y: end.y - 8))
            arrow.lineWidth = 2
            arrow.stroke()
            if let label = edge.label {
                let rect = NSRect(
                    x: min(max(0, labelPoint.x - edgeLabel.width / 2), max(0, natural.width - edgeLabel.width)),
                    y: min(max(0, labelPoint.y - edgeLabel.height / 2), max(0, natural.height - edgeLabel.height)),
                    width: min(edgeLabel.width, natural.width), height: edgeLabel.height)
                drawLabel(label, in: rect, fontSize: 12, background: true)
            }
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
