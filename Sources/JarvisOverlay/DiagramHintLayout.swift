import Foundation
import JarvisCore

struct DiagramHintLayout {
    let frames: [String: CGRect]
    let size: CGSize
    let horizontal: Bool

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
        let columnGap: CGFloat = 20
        let breadth = groups.map(\.count).max()!
        let columns = max(1, min(breadth, Int(
            (available.width - margin * 2 + columnGap) / (box.width + columnGap))))
        let rows = groups.flatMap { nodes in
            stride(from: 0, to: nodes.count, by: columns).map {
                Array(nodes[$0..<min($0 + columns, nodes.count)])
            }
        }
        let horizontalGaps = groups.map { gap(after: $0, labelExtent: edgeLabel.width) }
        let verticalGaps = rows.map { gap(after: $0, labelExtent: edgeLabel.height) }
        let hasBackEdge = graph.edges.contains { ranks[$0.to]! <= ranks[$0.from]! }
        let across = CGSize(
            width: margin * 2 + CGFloat(groups.count) * box.width + horizontalGaps.dropLast().reduce(0, +)
                + (hasBackEdge ? horizontalGaps.last! : 0),
            height: margin * 2 + CGFloat(breadth) * (box.height + 16) - 16)
        let down = CGSize(
            width: margin * 2 + CGFloat(columns) * (box.width + columnGap) - columnGap,
            height: margin * 2 + CGFloat(rows.count) * box.height + verticalGaps.dropLast().reduce(0, +)
                + (hasBackEdge ? verticalGaps.last! : 0))
        let preferAcross = graph.direction == .leftToRight
            ? across.height <= available.height || across.height < down.height
            : down.height > available.height && across.height < down.height
        horizontal = across.width <= available.width && preferAcross
        size = horizontal ? across : down
        var frames: [String: CGRect] = [:]
        var position = margin
        for (index, nodes) in (horizontal ? groups : rows).enumerated() {
            for (offset, node) in nodes.enumerated() {
                let origin: CGPoint
                if horizontal {
                    origin = CGPoint(x: position,
                        y: (size.height - CGFloat(nodes.count) * (box.height + 16) + 16) / 2
                            + CGFloat(offset) * (box.height + 16))
                } else {
                    origin = CGPoint(
                        x: (size.width - CGFloat(nodes.count) * (box.width + columnGap) + columnGap) / 2
                            + CGFloat(offset) * (box.width + columnGap), y: position)
                }
                frames[node.id] = CGRect(origin: origin, size: box)
            }
            position += horizontal ? box.width + horizontalGaps[index] : box.height + verticalGaps[index]
        }
        self.frames = frames
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
