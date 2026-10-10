import Foundation
import JarvisCore

struct DiagramHintLayout {
    let frames: [String: CGRect]
    let size: CGSize
    let horizontal: Bool
    let routes: [DiagramHintEdgeRoute]

    init(_ graph: DiagramHint, fitting available: CGSize, box: CGSize,
         edgeLabel: CGSize, margin: CGFloat) {
        let ranks = Self.ranks(graph)
        let groups = (0...ranks.values.max()!).map { rank in
            graph.nodes.filter { ranks[$0.id] == rank }
        }
        func gap(after nodes: [DiagramHint.Node], labelExtent: CGFloat) -> CGFloat {
            let outputs = nodes.map { node in
                graph.edges.filter { $0.from == node.id && $0.label != nil }.count
            }.max() ?? 0
            return max(28, CGFloat(outputs) * (labelExtent + 8) + 8)
        }
        let breadth = groups.map(\.count).max()!
        let compactBranches = breadth <= 3 && available.width >= 300
        let columnGap: CGFloat = compactBranches ? 12 : 24
        let minimumWidth = compactBranches ? min(box.width, 80) : box.width
        let horizontalGaps = groups.map { gap(after: $0, labelExtent: edgeLabel.width) + 16 }
        let across = CGSize(
            width: margin * 2 + CGFloat(groups.count) * box.width + horizontalGaps.dropLast().reduce(0, +)
                + (graph.edges.contains { ranks[$0.to]! <= ranks[$0.from]! } ? horizontalGaps.last! : 0),
            height: margin * 2 + CGFloat(breadth) * (box.height + 16) - 16
                + CGFloat(graph.edges.filter { ranks[$0.to]! != ranks[$0.from]! + 1 }.count) * 8)
        horizontal = graph.direction == .leftToRight && across.width <= available.width
        let hasReturns = graph.edges.contains { ranks[$0.to]! <= ranks[$0.from]! }
        let labelGutters = !horizontal && available.width >= box.width + 2 * (edgeLabel.width + 24)
        let leftSpace = labelGutters && hasReturns ? edgeLabel.width + 24 : margin
        var columns = max(1, min(breadth, Int(
            (available.width - leftSpace - margin + columnGap) / (minimumWidth + columnGap))))
        var rows: [[DiagramHint.Node]] = []
        var sideSpace = margin
        while true {
            rows = groups.flatMap { nodes in
                stride(from: 0, to: nodes.count, by: columns).map {
                    Array(nodes[$0..<min($0 + columns, nodes.count)])
                }
            }
            let rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().flatMap { index, nodes in
                nodes.map { ($0.id, index) }
            })
            let outsideEdges = graph.edges.filter { rowIndex[$0.to]! != rowIndex[$0.from]! + 1 }.count
            sideSpace = (labelGutters && outsideEdges > 0 ? edgeLabel.width + 24 : margin) + CGFloat(outsideEdges) * 8
            let fittingColumns = max(1, Int(
                (available.width - leftSpace - sideSpace + columnGap) / (minimumWidth + columnGap)))
            if fittingColumns >= columns { break }
            columns = fittingColumns
        }
        // Reserve outer lanes before sizing boxes so return arrows stay inside the viewport.
        sideSpace = min(sideSpace, max(margin, available.width - box.width - leftSpace))
        let actualBox = CGSize(width: horizontal ? box.width
            : min(box.width, max(1, (available.width - leftSpace - sideSpace
                - CGFloat(columns - 1) * columnGap) / CGFloat(columns))), height: box.height)
        let verticalGaps = rows.map { gap(after: $0, labelExtent: edgeLabel.height) + 16 }
        size = horizontal ? across : CGSize(
            width: leftSpace + sideSpace + CGFloat(columns) * (actualBox.width + columnGap) - columnGap,
            height: margin * 2 + CGFloat(rows.count) * box.height + verticalGaps.reduce(0, +))
        var frames: [String: CGRect] = [:]
        var position = margin
        for (index, nodes) in (horizontal ? groups : rows).enumerated() {
            for (offset, node) in nodes.enumerated() {
                var origin: CGPoint
                if horizontal {
                    origin = CGPoint(x: position,
                        y: (size.height - CGFloat(nodes.count) * (box.height + 16) + 16) / 2
                            + CGFloat(offset) * (box.height + 16))
                } else {
                    origin = CGPoint(
                        x: (size.width - sideSpace + leftSpace - CGFloat(nodes.count) * (actualBox.width + columnGap) + columnGap) / 2
                            + CGFloat(offset) * (actualBox.width + columnGap), y: position)
                }
                if !horizontal && nodes.count == 1 {
                    let parents = graph.edges.filter { $0.to == node.id }.compactMap { frames[$0.from]?.midX }
                    if !parents.isEmpty {
                        let center = parents.reduce(0, +) / CGFloat(parents.count)
                        origin.x = min(size.width - sideSpace - actualBox.width,
                                       max(leftSpace, center - actualBox.width / 2))
                    }
                }
                frames[node.id] = CGRect(origin: origin, size: actualBox)
            }
            position += horizontal ? box.width + horizontalGaps[index] : box.height + verticalGaps[index]
        }
        if !horizontal {
            for nodes in rows.reversed() {
                for node in nodes {
                    guard var frame = frames[node.id] else { continue }
                    let children = graph.edges.filter { $0.from == node.id }
                        .compactMap { frames[$0.to] }.filter { $0.minY > frame.maxY }
                    guard let first = children.first,
                          children.allSatisfy({ $0.minY == first.minY }) else { continue }
                    let center = children.map(\.midX).reduce(0, +) / CGFloat(children.count)
                    frame.origin.x = min(size.width - sideSpace - actualBox.width,
                                         max(leftSpace, center - actualBox.width / 2))
                    let overlaps = nodes.contains {
                        $0.id != node.id && frames[$0.id]!.insetBy(dx: -columnGap / 2, dy: 0).intersects(frame)
                    }
                    if !overlaps { frames[node.id] = frame }
                }
            }
        }
        self.frames = frames
        routes = DiagramHintEdgeRoute.make(graph, frames: frames, size: size,
            horizontal: horizontal, edgeLabel: edgeLabel)
    }

    private static func ranks(_ graph: DiagramHint) -> [String: Int] {
        var remaining = graph.nodes.map(\.id)
        var ranks: [String: Int] = [:]
        while !remaining.isEmpty {
            // Declaration order breaks a cycle; its back edge still renders.
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
