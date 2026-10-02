import Foundation
import JarvisCore

extension DiagramHintLayout {
    struct Arrangement {
        let frames: [String: CGRect]
        let size: CGSize
        let routes: [EdgeRoute]
    }

    static func arrange(_ graph: DiagramHint, groups: [[DiagramHint.Node]], breadth: CGFloat,
                                box: CGSize, label: CGSize, margin: CGFloat) -> Arrangement {
        let columnGap: CGFloat = 24
        let gutter = min(CGFloat(graph.edges.count) * 6 + 12,
                         max(margin, breadth - box.width - margin))
        let maxColumns = groups.map(\.count).max()!
        let columns = (1...maxColumns).last(where: { count in
            CGFloat(count) * (box.width + columnGap) - columnGap + margin + gutter <= breadth
        }) ?? 1
        let rows = groups.flatMap { nodes in
            stride(from: 0, to: nodes.count, by: columns).map {
                Array(nodes[$0..<min($0 + columns, nodes.count)])
            }
        }
        let rowForNode = Dictionary(uniqueKeysWithValues: rows.enumerated().flatMap { row, nodes in
            nodes.map { ($0.id, row) }
        })
        func isDirect(_ edge: DiagramHint.Edge) -> Bool {
            let labeledManyToMany = edge.label != nil
                && graph.edges.filter { $0.from == edge.from }.count > 1
                && graph.edges.filter { $0.to == edge.to }.count > 1
            return rowForNode[edge.to]! == rowForNode[edge.from]! + 1
                && graph.edges.filter { $0.from == edge.from && $0.to == edge.to }.count == 1
                && !labeledManyToMany
        }
        let bypasses = graph.edges.indices.filter { !isDirect(graph.edges[$0]) }
        let laneWidth = bypasses.isEmpty ? margin : gutter
        let contentWidth = CGFloat(columns) * box.width + CGFloat(columns - 1) * columnGap
        let width = margin + contentWidth + laneWidth
        var frames: [String: CGRect] = [:]
        var departures: [Int: CGFloat] = [:]
        var arrivals: [Int: CGFloat] = [:]
        var top = margin
        for (row, nodes) in rows.enumerated() {
            let incoming = graph.edges.indices.filter { rowForNode[graph.edges[$0].to] == row }
            for index in incoming {
                arrivals[index] = top
                top += 8
            }
            for (column, node) in nodes.enumerated() {
                frames[node.id] = CGRect(x: margin + (contentWidth - CGFloat(nodes.count) * box.width
                    - CGFloat(nodes.count - 1) * columnGap) / 2 + CGFloat(column) * (box.width + columnGap),
                    y: top, width: box.width, height: box.height)
            }
            top += box.height
            let outgoing = graph.edges.indices.filter { rowForNode[graph.edges[$0].from] == row }
                .sorted { !isDirect(graph.edges[$0]) && isDirect(graph.edges[$1]) }
            if outgoing.isEmpty { top += 16 }
            for index in outgoing {
                let extent = graph.edges[index].label == nil ? 0 : label.height
                top += 12 + extent / 2
                departures[index] = top
                top += extent / 2
            }
            top += 12
        }
        let size = CGSize(width: width, height: top + margin)
        let routes = graph.edges.enumerated().map { index, edge in
            let from = frames[edge.from]!
            let to = frames[edge.to]!
            let outgoing = graph.edges.indices.filter { graph.edges[$0].from == edge.from }
            let incoming = graph.edges.indices.filter { graph.edges[$0].to == edge.to }
            let output = outgoing.firstIndex(of: index)!
            let input = incoming.firstIndex(of: index)!
            let direct = isDirect(edge)
            let portInset = min(12, box.width / 8) * CGFloat(output + 1) / CGFloat(outgoing.count + 1)
            let startX = outgoing.count == 1 && direct ? from.midX
                : direct && to.midX > from.midX ? from.maxX - portInset : from.minX + portInset
            let portSpacing = min(8, max(0, box.width - 8) / CGFloat(max(1, incoming.count - 1)))
            let endX = to.midX + (CGFloat(input) - CGFloat(incoming.count - 1) / 2) * portSpacing
            let start = CGPoint(x: startX, y: from.maxY)
            let departure = departures[index]!
            let end = CGPoint(x: endX, y: to.minY)
            let labelCenter: CGPoint
            var points = [start, CGPoint(x: start.x, y: departure)]
            if direct {
                labelCenter = CGPoint(x: incoming.count > 1 ? from.midX : to.midX, y: departure)
                if incoming.count > 1 {
                    let arrival = arrivals[index]!
                    points += [CGPoint(x: start.x, y: arrival), CGPoint(x: endX, y: arrival)]
                } else {
                    points += [CGPoint(x: endX, y: departure)]
                }
            } else {
                let laneIndex = bypasses.firstIndex(of: index)!
                let lane = margin + contentWidth
                    + laneWidth * CGFloat(laneIndex + 1) / CGFloat(bypasses.count + 1)
                labelCenter = CGPoint(x: from.midX, y: departure)
                points += [CGPoint(x: lane, y: departure), CGPoint(x: lane, y: arrivals[index]!),
                           CGPoint(x: endX, y: arrivals[index]!)]
            }
            points.append(end)
            return EdgeRoute(points: points, labelCenter: labelCenter)
        }
        return Arrangement(frames: frames, size: size, routes: routes)
    }
}
