import Foundation
import JarvisCore

struct DiagramHintConnectionLayout {
    struct Row {
        let source: String
        let target: String?
        let edgeIndex: Int?
        let sourceFrame: CGRect
        let targetFrame: CGRect
        let labelFrame: CGRect
    }
    let rows: [Row]
    let size: CGSize

    init(_ graph: DiagramHint, width: CGFloat, nodeHeight: CGFloat, labelHeight: CGFloat,
         headerHeight: CGFloat) {
        let width = max(1, min(360, width))
        let margin = min(16, width / 20)
        let arrowWidth = min(40, width / 8)
        let nodeWidth = (width - margin * 2 - arrowWidth) / 2
        let connected = Set(graph.edges.flatMap { [$0.from, $0.to] })
        let entries: [(String, String?, Int?)] = graph.edges.enumerated().map {
            ($0.element.from, $0.element.to, $0.offset)
        } + graph.nodes.filter { !connected.contains($0.id) }.map { ($0.id, nil, nil) }
        var y = headerHeight + 16
        var rows: [Row] = []
        for (source, target, edgeIndex) in entries {
            let label = CGRect(x: margin, y: y, width: width - 2 * margin, height: labelHeight)
            y += labelHeight + 8
            let from = CGRect(x: margin, y: y, width: nodeWidth, height: nodeHeight)
            let to = CGRect(x: margin + nodeWidth + arrowWidth, y: y, width: nodeWidth, height: nodeHeight)
            rows.append(Row(source: source, target: target, edgeIndex: edgeIndex,
                            sourceFrame: from, targetFrame: to, labelFrame: label))
            y += nodeHeight + 24
        }
        self.rows = rows
        size = CGSize(width: width, height: y)
    }
}
