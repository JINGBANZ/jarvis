import Foundation
import JarvisCore

struct DiagramHintEdgeRoute {
    let points: [CGPoint]
    let labelCenter: CGPoint

    static func make(_ graph: DiagramHint, frames: [String: CGRect], size: CGSize,
                     horizontal: Bool, edgeLabel: CGSize) -> [Self] {
        func normalized(_ rect: CGRect) -> CGRect {
            horizontal ? CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width) : rect
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: y, y: x) : CGPoint(x: x, y: y)
        }
        let boxes = frames.mapValues(normalized)
        func rowOffset(_ box: CGRect) -> CGFloat {
            let row = boxes.values.filter { $0.minY == box.minY }.sorted { $0.minX < $1.minX }
            let index = row.firstIndex(of: box)!
            return CGFloat(index) * 8 / CGFloat(max(1, row.count - 1))
        }
        let breadth = horizontal ? size.height : size.width
        let outerStart = boxes.values.map(\.maxX).max()! + 8
        let candidates = graph.edges.enumerated().map { index, edge in
            let from = boxes[edge.from]!, to = boxes[edge.to]!
            let start = CGPoint(x: from.midX, y: from.maxY)
            let end = CGPoint(x: to.midX, y: to.minY)
            let labelIndex = graph.edges.prefix(index).filter {
                $0.from == edge.from && $0.label != nil
            }.count
            let labelExtent = horizontal ? edgeLabel.width : edgeLabel.height
            let offset = edge.label == nil ? 12 : 4 + (CGFloat(labelIndex) + 0.5) * (labelExtent + 8)
            let track = start.y + offset + rowOffset(from)
            let path = [start, CGPoint(x: start.x, y: track), CGPoint(x: end.x, y: track), end]
            let obstructed = boxes.contains { id, box in
                guard id != edge.from && id != edge.to else { return false }
                return zip(path, path.dropFirst()).contains { a, b in
                    let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                        width: max(0.1, abs(a.x - b.x)), height: max(0.1, abs(a.y - b.y)))
                    return segment.intersects(box.insetBy(dx: 1, dy: 1))
                }
            }
            return (path: path, label: CGPoint(x: start.x, y: track), outside: end.y <= track || obstructed, arrival: end.y - 12 + rowOffset(to))
        }
        let outerCount = candidates.filter(\.outside).count
        let laneSpacing = min(8, max(0, breadth - 4 - outerStart) / CGFloat(max(1, outerCount - 1)))
        var outsideIndex = 0
        return candidates.map { candidate in
            var path = candidate.path
            let start = path.first!, end = path.last!, track = candidate.label.y
            if candidate.outside {
                let lane = min(breadth - 4, outerStart + CGFloat(outsideIndex) * laneSpacing)
                outsideIndex += 1
                path = [start, CGPoint(x: start.x, y: track), CGPoint(x: lane, y: track),
                        CGPoint(x: lane, y: candidate.arrival), CGPoint(x: end.x, y: candidate.arrival), end]
            }
            var compact: [CGPoint] = []
            for next in path {
                if compact.last == next { continue }
                if compact.count >= 2 {
                    let a = compact[compact.count - 2], b = compact[compact.count - 1]
                    if (a.x == b.x && b.x == next.x && (b.y - a.y) * (next.y - b.y) >= 0)
                        || (a.y == b.y && b.y == next.y && (b.x - a.x) * (next.x - b.x) >= 0) {
                        compact.removeLast()
                    }
                }
                compact.append(next)
            }
            return Self(points: compact.map { point($0.x, $0.y) },
                        labelCenter: point(start.x, track))
        }
    }
}
