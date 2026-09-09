import Foundation

/// A small, inert subset of Mermaid flowcharts for private high-level-design hints. Deliberately
/// excludes directives, links, HTML, styling, and other diagram types: the overlay needs only boxes
/// and arrows, so rendering never executes model-supplied code or loads remote resources.
public struct DiagramHint: Sendable, Equatable {
    public enum Direction: Sendable { case leftToRight, topDown }
    public struct Node: Sendable, Equatable {
        public let id: String
        public let label: String
    }
    public struct Edge: Sendable, Equatable {
        public let from: String
        public let to: String
        public let label: String?
    }
    public let direction: Direction
    public let nodes: [Node]
    public let edges: [Edge]

    /// Accepts one declaration or connection per line, with optional inline box declarations.
    /// Every endpoint must have a box label somewhere in the source; conflicting labels are invalid.
    public init?(mermaid: String) {
        guard mermaid.utf8.count <= 8_000 else { return nil }
        let lines = mermaid.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let header = lines.first else { return nil }
        switch header {
        case "flowchart LR", "graph LR": direction = .leftToRight
        case "flowchart TD", "graph TD", "flowchart TB", "graph TB": direction = .topDown
        default: return nil
        }
        let endpoint = #"([A-Za-z][A-Za-z0-9_]{0,31})(?:\[(?:"([^"\[\]<>\p{Cc}]{1,48})"|([^"\[\]<>\p{Cc}]{1,48}))\])?"#
        guard let nodePattern = try? NSRegularExpression(pattern: "^" + endpoint + "$"),
              let edgePattern = try? NSRegularExpression(
                pattern: "^" + endpoint + #"\s*-->\s*(?:\|([^|<>\p{Cc}]{1,32})\|\s*)?"# + endpoint + "$")
        else { return nil }
        var nodes: [Node] = []
        var edges: [Edge] = []
        func readEndpoint(_ captures: [String?], at index: Int) -> String? {
            guard let id = captures[index] else { return nil }
            if let rawLabel = captures[index + 1] ?? captures[index + 2] {
                let label = rawLabel.trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { return nil }
                if let existing = nodes.first(where: { $0.id == id }) {
                    guard existing.label == label else { return nil }
                } else {
                    nodes.append(Node(id: id, label: label))
                }
            }
            return id
        }
        for line in lines.dropFirst() {
            if let captures = Self.captures(edgePattern, in: line) {
                guard let from = readEndpoint(captures, at: 0),
                      let to = readEndpoint(captures, at: 4), from != to else { return nil }
                edges.append(Edge(from: from, to: to, label: captures[3]))
            } else if let captures = Self.captures(nodePattern, in: line) {
                guard readEndpoint(captures, at: 0) != nil,
                      captures[1] != nil || captures[2] != nil else { return nil }
            } else {
                return nil
            }
            guard nodes.count <= 12, edges.count <= 24 else { return nil }
        }
        let ids = Set(nodes.map(\.id))
        guard !nodes.isEmpty, edges.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) }) else {
            return nil
        }
        self.nodes = nodes
        self.edges = edges
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String?]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
