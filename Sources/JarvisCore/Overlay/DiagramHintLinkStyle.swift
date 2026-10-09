import Foundation

struct DiagramHintLinkStyle {
    let indices: [Int]
    let stroke: UInt32
    let width: Double?

    init?(_ line: String) {
        let pattern = #"^linkStyle ([0-9]+(?:,[0-9]+)*) stroke:#([0-9A-Fa-f]{6})(?:,stroke-width:([1-4])px)?;?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        func capture(_ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
        let tokens = capture(1)!.split(separator: ",")
        let indices = tokens.compactMap { Int($0) }
        guard indices.count == tokens.count, let stroke = UInt32(capture(2)!, radix: 16) else { return nil }
        self.indices = indices
        self.stroke = stroke
        width = capture(3).flatMap(Double.init)
    }
}
