import AppKit
import JarvisCore

extension DiagramHintImage {
    static func renderConnections(_ graph: DiagramHint, fitting available: CGSize) -> NSImage {
        let initial = DiagramHintConnectionLayout(graph, width: available.width,
            nodeHeight: 36, labelHeight: 20, headerHeight: 0)
        let nodeWidth = initial.rows[0].sourceFrame.width
        let nodeHeight = max(36, graph.nodes.map {
            labelHeight($0.label, width: max(1, nodeWidth - 16), fontSize: 15) + 16
        }.max() ?? 36)
        let title = "Connections — repeated boxes represent the same component"
        let headerHeight = labelHeight(title, width: max(1, initial.size.width - 32), fontSize: 12) + 16
        let edgeHeight = max(20, graph.edges.compactMap(\.label).map {
            labelHeight($0, width: initial.rows[0].labelFrame.width, fontSize: 12)
        }.max() ?? 20)
        let layout = DiagramHintConnectionLayout(graph, width: available.width,
            nodeHeight: nodeHeight, labelHeight: edgeHeight, headerHeight: headerHeight)
        let labels = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.label) })
        let image = NSImage(size: layout.size)
        image.lockFocusFlipped(true)
        drawLabel(title, in: CGRect(x: 16, y: 8, width: max(1, layout.size.width - 32),
                                   height: headerHeight - 16), fontSize: 12, background: false)
        for row in layout.rows {
            if let index = row.edgeIndex, let target = row.target {
                let edge = graph.edges[index]
                drawLabel(edge.label ?? "Connection", in: row.labelFrame, fontSize: 12,
                          background: false, color: edge.stroke == nil ? .white : strokeColor(edge))
                drawEdge(DiagramHintEdgeRoute(points: [
                    CGPoint(x: row.sourceFrame.maxX, y: row.sourceFrame.midY),
                    CGPoint(x: row.targetFrame.minX, y: row.targetFrame.midY)
                ], labelCenter: .zero), edge: edge)
                drawNode(labels[target]!, in: row.targetFrame)
            } else {
                drawLabel("Unconnected component", in: row.labelFrame, fontSize: 12, background: false)
            }
            drawNode(labels[row.source]!, in: row.sourceFrame)
            let separator = NSBezierPath()
            separator.move(to: CGPoint(x: row.labelFrame.minX, y: row.sourceFrame.maxY + 12))
            separator.line(to: CGPoint(x: row.labelFrame.maxX, y: row.sourceFrame.maxY + 12))
            NSColor(white: 0.35, alpha: 1).setStroke()
            separator.lineWidth = 0.5
            separator.stroke()
        }
        image.unlockFocus()
        return image
    }
}
