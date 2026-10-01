import Foundation
import JarvisCore

struct FoldedDiagramHintLayout {
    struct EdgeRoute {
        let points: [CGPoint]
        let labelCenter: CGPoint
    }

    let frames: [String: CGRect]
    let size: CGSize
    let routes: [EdgeRoute]

    init?(graph: DiagramHint, groups: [[DiagramHint.Node]], width: CGFloat,
          box: CGSize, edgeLabel: CGSize, margin: CGFloat) {
        for channels in 3...max(3, graph.edges.count) {
            if let candidate = Self(graph: graph, groups: groups, width: width, box: box,
                                    edgeLabel: edgeLabel, margin: margin, channels: channels) {
                self = candidate
                return
            }
        }
        return nil
    }

    private init?(graph: DiagramHint, groups: [[DiagramHint.Node]], width: CGFloat,
                  box: CGSize, edgeLabel: CGSize, margin outerMargin: CGFloat, channels: Int) {
        let margin = max(outerMargin, CGFloat(channels * 4 + 12))
        let gutter = CGFloat(channels * 4 + 8)
        let bandGap = CGFloat(channels * 4 + 8)
        let columns = min(groups.count, Int((width - margin * 2 + gutter) / (box.width + gutter)))
        guard groups.count >= 4, columns >= 2 else { return nil }
        let bands = stride(from: 0, to: groups.count, by: columns).map {
            Array(groups[$0..<min($0 + columns, groups.count)])
        }
        var frames: [String: CGRect] = [:]
        var bandForNode: [String: Int] = [:]
        var bandTops: [CGFloat] = []
        var bandBottoms: [CGFloat] = []
        var top = margin
        func clearance(_ node: DiagramHint.Node) -> CGFloat {
            let labels = graph.edges.filter { $0.from == node.id && $0.label != nil }.count
            return max(28, CGFloat(labels) * (edgeLabel.height + 8) + 8)
        }
        for (bandIndex, band) in bands.enumerated() {
            bandTops.append(top)
            let height = band.map { nodes in
                nodes.reduce(CGFloat.zero) { $0 + box.height + clearance($1) }
            }.max()!
            for (offset, nodes) in band.enumerated() {
                let column = bandIndex.isMultiple(of: 2) ? offset : columns - offset - 1
                var y = top
                for node in nodes {
                    frames[node.id] = CGRect(x: margin + CGFloat(column) * (box.width + gutter),
                        y: y, width: box.width, height: box.height)
                    bandForNode[node.id] = bandIndex
                    y += box.height + clearance(node)
                }
            }
            bandBottoms.append(top + height)
            top += height + bandGap
        }
        let size = CGSize(width: margin * 2 + CGFloat(columns) * (box.width + gutter) - gutter,
                          height: top - bandGap + margin)
        let ranks = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { rank, nodes in
            nodes.map { ($0.id, rank) }
        })
        func route(_ edge: DiagramHint.Edge, index: Int, channel: Int) -> EdgeRoute {
            let from = frames[edge.from]!
            let to = frames[edge.to]!
            let sourceBand = bandForNode[edge.from]!
            let targetBand = bandForNode[edge.to]!
            let sourceForward = sourceBand.isMultiple(of: 2)
            let targetForward = targetBand.isMultiple(of: 2)
            let labelIndex = graph.edges.prefix(index).filter {
                $0.from == edge.from && $0.label != nil
            }.count
            let track = from.maxY + (edge.label == nil ? 8
                : 4 + (CGFloat(labelIndex) + 0.5) * (edgeLabel.height + 8))
            let label = CGPoint(x: from.midX, y: track)
            let offset = CGFloat(4 + channel * 4)
            let exitX = sourceForward ? from.maxX + offset : from.minX - offset
            let entryX = targetForward ? to.minX - offset : to.maxX + offset
            let end = CGPoint(x: targetForward ? to.minX : to.maxX, y: to.midY)
            var points = [CGPoint(x: from.midX, y: from.maxY), label,
                          CGPoint(x: exitX, y: track)]
            if sourceBand == targetBand && ranks[edge.to]! == ranks[edge.from]! + 1 {
                points += [CGPoint(x: entryX, y: track), CGPoint(x: entryX, y: to.midY)]
            } else if sourceBand == targetBand {
                let lane = bandBottoms[sourceBand] + CGFloat(channel * 4)
                points += [CGPoint(x: exitX, y: lane), CGPoint(x: entryX, y: lane),
                           CGPoint(x: entryX, y: to.midY)]
            } else {
                let inset = 2 + CGFloat(channel * 3)
                let lane = sourceForward ? size.width - inset : inset
                let departure = bandBottoms[sourceBand] + CGFloat(channel * 4)
                let arrival = bandTops[targetBand] - bandGap + 4 + CGFloat(channel * 4)
                points += [CGPoint(x: exitX, y: departure), CGPoint(x: lane, y: departure),
                           CGPoint(x: lane, y: arrival), CGPoint(x: entryX, y: arrival),
                           CGPoint(x: entryX, y: to.midY)]
            }
            points.append(end)
            return EdgeRoute(points: points, labelCenter: label)
        }
        var routes: [EdgeRoute] = []
        for (index, edge) in graph.edges.enumerated() {
            let candidate = (0..<channels).lazy.map { route(edge, index: index, channel: $0) }.first { next in
                routes.enumerated().allSatisfy { previousIndex, previous in
                    !Self.overlaps(next, previous, sameSource: edge.from == graph.edges[previousIndex].from,
                                   sameTarget: edge.to == graph.edges[previousIndex].to)
                }
            }
            guard let candidate else { return nil }
            routes.append(candidate)
        }
        self.frames = frames
        self.size = size
        self.routes = routes
    }

    private static func overlaps(_ first: EdgeRoute, _ second: EdgeRoute,
                                 sameSource: Bool, sameTarget: Bool) -> Bool {
        for i in 0..<(first.points.count - 1) {
            for j in 0..<(second.points.count - 1) {
                if sameSource && ((i == 0 && j == 0)
                    || (i < 3 && j < 3 && first.labelCenter == second.labelCenter)) { continue }
                if sameTarget && i >= first.points.count - 3 && j >= second.points.count - 3 { continue }
                let a = first.points[i], b = first.points[i + 1]
                let c = second.points[j], d = second.points[j + 1]
                if a.x == b.x && c.x == d.x && a.x == c.x
                    && max(min(a.y, b.y), min(c.y, d.y)) < min(max(a.y, b.y), max(c.y, d.y)) {
                    return true
                }
                if a.y == b.y && c.y == d.y && a.y == c.y
                    && max(min(a.x, b.x), min(c.x, d.x)) < min(max(a.x, b.x), max(c.x, d.x)) {
                    return true
                }
            }
        }
        return false
    }
}
