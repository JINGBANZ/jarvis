import Foundation

struct AccessibleTextExtraction: Sendable, Equatable {
    let text: String
    let truncated: Bool
}

/// Converts a value-only web-area tree into bounded text without changing punctuation, case, or
/// identifier spelling. Limits are enforced during traversal so a hostile page cannot grow an
/// unbounded intermediate string.
struct AccessibleTextExtractor: Sendable {
    private let byteLimit: Int
    private let nodeLimit: Int
    private let depthLimit: Int

    init(byteLimit: Int = 32_768, nodeLimit: Int = 4_096, depthLimit: Int = 64) {
        self.byteLimit = max(0, byteLimit)
        self.nodeLimit = max(0, nodeLimit)
        self.depthLimit = max(0, depthLimit)
    }

    func extract(_ root: AccessibilityNode) -> AccessibleTextExtraction {
        var stack: [(node: AccessibilityNode, depth: Int)] = [(root, 0)]
        var lines: [String] = []
        var byteCount = 0
        var visited = 0
        var truncated = false
        var lastLine: String?

        while let next = stack.popLast() {
            guard visited < nodeLimit else {
                truncated = true
                break
            }
            visited += 1

            if next.node.isSecure || next.node.role == "AXSecureTextField" { continue }

            if let raw = next.node.text {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty, line != lastLine {
                    let separatorBytes = lines.isEmpty ? 0 : 1
                    let available = max(0, byteLimit - byteCount - separatorBytes)
                    let bounded = Self.prefix(line, bytes: available)
                    if !bounded.isEmpty {
                        lines.append(bounded)
                        byteCount += separatorBytes + bounded.utf8.count
                        lastLine = bounded
                    }
                    if bounded.utf8.count < line.utf8.count {
                        truncated = true
                        break
                    }
                }
            }

            if next.depth >= depthLimit {
                if !next.node.children.isEmpty { truncated = true }
                continue
            }
            for child in next.node.children.reversed() {
                stack.append((child, next.depth + 1))
            }
        }

        return AccessibleTextExtraction(text: lines.joined(separator: "\n"), truncated: truncated)
    }

    private static func prefix(_ text: String, bytes limit: Int) -> String {
        var bytes = 0
        var end = text.unicodeScalars.startIndex
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= limit else { break }
            bytes += size
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }
}
