import AppKit
import JarvisCore

/// Native, memory-only rendering for the box-and-arrow Mermaid subset. An attachment keeps the
/// diagram with its hint in the existing scrollable, capture-excluded panel, without a third window.
@MainActor
enum DiagramHintImage {
    static func render(_ graph: DiagramHint, width: CGFloat) -> NSImage {
        let gap: CGFloat = 100
        let margin: CGFloat = 36
        let ranks = ranks(graph)
        let rankCount = (ranks.values.max() ?? 0) + 1
        let groups = (0..<rankCount).map { rank in graph.nodes.filter { ranks[$0.id] == rank } }
        // A long LR graph becomes a vertical sketch in a narrow overlay. Wrap wide layers too:
        // scrolling vertically preserves readable labels instead of shrinking an entire architecture.
        let columns = max(1, Int((width - margin * 2 + gap) / (128 + gap)))
        let horizontal = graph.direction == .leftToRight && rankCount <= columns
        let usedColumns = horizontal ? rankCount : min(columns, groups.map(\.count).max() ?? 1)
        let boxSize = NSSize(width: min(172, max(1,
            (width - margin * 2 - CGFloat(usedColumns - 1) * gap) / CGFloat(usedColumns))), height: 88)
        var frames: [String: NSRect] = [:]
        var rowOffset = 0
        for (rank, nodes) in groups.enumerated() {
            for (index, node) in nodes.enumerated() {
                let row = horizontal ? index : rowOffset + index / columns
                let column = horizontal ? rank : index % columns
                let rowCount = horizontal ? rankCount : min(columns, nodes.count - (index / columns) * columns)
                let rowWidth = CGFloat(rowCount) * (boxSize.width + gap) - gap
                let x = (width - rowWidth) / 2 + CGFloat(column) * (boxSize.width + gap)
                frames[node.id] = NSRect(x: x, y: margin + CGFloat(row) * (boxSize.height + gap),
                                        width: boxSize.width, height: boxSize.height)
            }
            rowOffset += (nodes.count + columns - 1) / columns
        }
        let natural = NSSize(width: max(1, width), height: (frames.values.map(\.maxY).max() ?? 0) + margin)
        let image = NSImage(size: natural)
        image.lockFocusFlipped(true)
        for edge in graph.edges {
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
            if forward && !interveningBox {
                let middle = horizontal ? (start.x + end.x) / 2 : (start.y + end.y) / 2
                let first = horizontal ? NSPoint(x: middle, y: start.y) : NSPoint(x: start.x, y: middle)
                let second = horizontal ? NSPoint(x: middle, y: end.y) : NSPoint(x: end.x, y: middle)
                path.line(to: first)
                path.line(to: second)
                labelPoint = horizontal
                    ? NSPoint(x: middle, y: end.y - 20)
                    : NSPoint(x: end.x, y: middle)
            } else {
                // Feedback and bypass arrows travel around the outside, avoiding every
                // intervening box (including wrapped nodes in a wide layer).
                if horizontal {
                    path.line(to: NSPoint(x: start.x + 16, y: start.y))
                    path.line(to: NSPoint(x: start.x + 16, y: natural.height - 12))
                    path.line(to: NSPoint(x: end.x - 16, y: natural.height - 12))
                    path.line(to: NSPoint(x: end.x - 16, y: end.y))
                    labelPoint = NSPoint(x: natural.width / 2, y: natural.height - 12)
                } else {
                    path.line(to: NSPoint(x: start.x, y: start.y + 16))
                    path.line(to: NSPoint(x: natural.width - 12, y: start.y + 16))
                    path.line(to: NSPoint(x: natural.width - 12, y: end.y - 16))
                    path.line(to: NSPoint(x: end.x, y: end.y - 16))
                    labelPoint = NSPoint(x: (natural.width - 12 + end.x) / 2, y: end.y - 36)
                }
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
                drawLabel(label, in: NSRect(x: labelPoint.x - 40, y: labelPoint.y - 20, width: 80, height: 40),
                          fontSize: 12, background: true)
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

    private static func ranks(_ graph: DiagramHint) -> [String: Int] {
        var remaining = graph.nodes.map(\.id)
        var ranks: [String: Int] = [:]
        while !remaining.isEmpty {
            // Layer a DAG by its longest incoming path. For a cycle, break the layout tie in
            // declaration order; the unbroken graph still renders its feedback arrow.
            let ready = remaining.first { id in
                graph.edges.filter { $0.to == id }.allSatisfy { ranks[$0.from] != nil }
            } ?? remaining[0]
            let predecessors = graph.edges.filter { $0.to == ready }.compactMap { ranks[$0.from] }
            ranks[ready] = predecessors.max().map { $0 + 1 } ?? 0
            remaining.removeAll { $0 == ready }
        }
        return ranks
    }
}
