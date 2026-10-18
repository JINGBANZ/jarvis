import Foundation
import JarvisCore

struct ReferenceSearchNameScope {
    let documents: [String]?
    let query: String

    init(query: String, names: [(document: String, name: String, base: String)], budget: ReferenceQueryBudget) throws {
        var remaining = ReferenceSearchTokenizer.folded(query)
        var grouped: [String: [(document: String, name: String, base: String)]] = [:]
        for name in names {
            try budget.check()
            grouped[ReferenceSearchTokenizer.folded(name.base), default: []].append(name)
        }
        let ordered = grouped.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        var matched = false
        var selected = Set<String>()
        // Consume complete longer names before their suffixes, as PrepMaterialIndex does.
        for base in ordered {
            try budget.check()
            let pattern = #"(?<![\p{L}\p{N}\p{M}_./\\-])"# + NSRegularExpression.escapedPattern(for: base)
                + #"(?:[ \t]+\[([^\]\r\n]*)\])?(?![\p{L}\p{N}\p{M}_/\\-]|\.[\p{L}\p{N}\p{M}_-])"#
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(remaining.startIndex..<remaining.endIndex, in: remaining)
            for match in expression.matches(in: remaining, range: range) {
                try budget.check()
                matched = true
                if let qualifier = Range(match.range(at: 1), in: remaining) {
                    let name = base + " [" + remaining[qualifier] + "]"
                    for entry in grouped[base] ?? [] {
                        try budget.check()
                        if ReferenceSearchTokenizer.folded(entry.name) == name { selected.insert(entry.document) }
                    }
                } else {
                    for entry in grouped[base] ?? [] {
                        try budget.check()
                        selected.insert(entry.document)
                    }
                }
            }
            remaining = expression.stringByReplacingMatches(in: remaining, range: range, withTemplate: " ")
        }
        try budget.check()
        documents = matched ? selected.sorted() : nil
        self.query = matched ? remaining : query
    }
}
