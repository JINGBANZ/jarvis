import Foundation
import JarvisCore

struct DiagramHintLayout {
    struct EdgeRoute {
        let points: [CGPoint]
        let labelCenter: CGPoint
    }

    let frames: [String: CGRect]
    let size: CGSize
    let horizontal: Bool
    let routes: [EdgeRoute]

    init(_ graph: DiagramHint, fitting available: CGSize, box: CGSize,
         edgeLabel: CGSize, margin: CGFloat) {
        let ranks = Self.ranks(graph)
        let groups = (0...ranks.values.max()!).map { rank in
            graph.nodes.filter { ranks[$0.id] == rank }
        }
        if graph.direction == .leftToRight {
            let across = Self.arrange(graph, groups: groups, breadth: .greatestFiniteMagnitude,
                box: CGSize(width: box.height, height: box.width),
                label: CGSize(width: edgeLabel.height, height: edgeLabel.width), margin: margin)
            if across.size.height <= available.width {
                frames = across.frames.mapValues {
                    CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width)
                }
                size = CGSize(width: across.size.height, height: across.size.width)
                horizontal = true
                routes = across.routes.map { route in
                    EdgeRoute(points: route.points.map { CGPoint(x: $0.y, y: $0.x) },
                        labelCenter: CGPoint(x: route.labelCenter.y, y: route.labelCenter.x))
                }
                return
            }
        }
        let down = Self.arrange(graph, groups: groups, breadth: available.width,
                               box: box, label: edgeLabel, margin: margin)
        frames = down.frames
        size = down.size
        horizontal = false
        routes = down.routes
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
