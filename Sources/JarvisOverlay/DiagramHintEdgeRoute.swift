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
            let siblings = graph.edges.filter { $0.from == edge.from }.compactMap { boxes[$0.to] }
            let split = !horizontal && siblings.count > 1
                && siblings.allSatisfy { $0.minY == to.minY && $0.minY > from.maxY }
                && graph.edges.filter { $0.to == edge.to }.count == 1
            let track = split ? start.y + 12 : start.y + offset + rowOffset(from)
            let path = [start, CGPoint(x: start.x, y: track), CGPoint(x: end.x, y: track), end]
            let obstructed = boxes.contains { id, box in
                guard id != edge.from && id != edge.to else { return false }
                return zip(path, path.dropFirst()).contains { a, b in
                    let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                        width: max(0.1, abs(a.x - b.x)), height: max(0.1, abs(a.y - b.y)))
                    return segment.intersects(box.insetBy(dx: 1, dy: 1))
                }
            }
            let label = split && !obstructed
                ? CGPoint(x: end.x, y: track + edgeLabel.height / 2 + 8)
                : CGPoint(x: start.x, y: track)
            return (path: path, track: track, label: label, outside: end.y <= track || obstructed, returning: to.minY <= from.minY, hasLabel: edge.label != nil, target: to, arrival: end.y - 12 + rowOffset(to))
        }
        let outerCount = candidates.filter(\.outside).count
        let laneSpacing = min(8, max(0, breadth - 4 - outerStart) / CGFloat(max(1, outerCount - 1)))
        var outsideIndex = 0
        var returnIndex = 0
        var labelFrames: [CGRect] = []
        let innerLeft = boxes.values.map(\.minX).min()!
        let innerRight = boxes.values.map(\.maxX).max()!

        return candidates.map { candidate in
            var path = candidate.path
            let start = path.first!, end = path.last!, track = candidate.track
            var label = candidate.label
            if candidate.outside {
                let left = candidate.returning
                let gutter = left ? innerLeft : breadth - innerRight
                let canLabel = !horizontal && gutter >= edgeLabel.width + 16
                let lane: CGFloat
                if left {
                    lane = max(4, (canLabel ? innerLeft / 2 : innerLeft - 8) - CGFloat(returnIndex) * 4)
                    returnIndex += 1
                } else {
                    lane = canLabel ? innerRight + edgeLabel.width / 2 + 8 + CGFloat(outsideIndex) * min(8, max(0, gutter - edgeLabel.width - 16) / CGFloat(max(1, outerCount - 1)))
                        : min(breadth - 4, outerStart + CGFloat(outsideIndex) * laneSpacing)
                    outsideIndex += 1
                }
                if canLabel && candidate.hasLabel {
                    let minY = min(track, candidate.arrival) + edgeLabel.height / 2 + 4
                    let maxY = max(track, candidate.arrival) - edgeLabel.height / 2 - 4
                    var centerY = (minY + maxY) / 2
                    while centerY <= maxY {
                        let rect = CGRect(x: lane - edgeLabel.width / 2, y: centerY - edgeLabel.height / 2,
                                          width: edgeLabel.width, height: edgeLabel.height + 8)
                        if !labelFrames.contains(where: { $0.intersects(rect) }) {
                            label = CGPoint(x: lane, y: centerY)
                            labelFrames.append(rect)
                            break
                        }
                        centerY += edgeLabel.height + 8
                    }
                }
                path = [start, CGPoint(x: start.x, y: track), CGPoint(x: lane, y: track),
                        CGPoint(x: lane, y: candidate.arrival), CGPoint(x: end.x, y: candidate.arrival), end]
                if !horizontal {
                    let target = candidate.target
                    let side = CGPoint(x: left ? target.minX : target.maxX, y: target.midY)
                    let approach = CGRect(x: min(lane, side.x), y: side.y - 0.5,
                                          width: abs(side.x - lane), height: 1)
                    let clear = boxes.values.allSatisfy {
                        $0 == target || !approach.intersects($0.insetBy(dx: 1, dy: 1))
                    }
                    if clear {
                        path = [start, CGPoint(x: start.x, y: track), CGPoint(x: lane, y: track),
                                CGPoint(x: lane, y: side.y), side]
                    }
                }
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
                        labelCenter: point(label.x, label.y))
        }
    }
}
