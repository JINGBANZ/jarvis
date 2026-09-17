import Foundation

struct AccessibleTextExtraction: Sendable, Equatable {
    let text: String
    let truncated: Bool
}

/// Keeps punctuation, case, and identifier spelling verbatim. Limits apply during traversal so a
/// hostile page cannot grow an unbounded intermediate string.
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
        while let next = stack.popLast() {
            guard visited < nodeLimit else {
                truncated = true
                break
            }
            visited += 1

            if next.node.isSecure || next.node.role == "AXSecureTextField" { continue }

            let block = Self.blockText(next.node)
            if let block {
                let separatorBytes = lines.isEmpty ? 0 : 1
                let available = max(0, byteLimit - byteCount - separatorBytes)
                let bounded = Self.prefix(block, bytes: available)
                if !bounded.isEmpty {
                    lines.append(bounded)
                    byteCount += separatorBytes + bounded.utf8.count
                }
                if bounded.utf8.count < block.utf8.count {
                    truncated = true
                    break
                }
                if Self.blockRoles.contains(next.node.role) { continue }
            }

            if next.depth >= depthLimit {
                if !next.node.children.isEmpty { truncated = true }
                continue
            }
            let ordered = next.node.children.enumerated().sorted { left, right in
                let leftPriority = Self.containsEditor(left.element)
                let rightPriority = Self.containsEditor(right.element)
                return leftPriority == rightPriority ? left.offset < right.offset : leftPriority
            }
            for child in ordered.reversed() {
                stack.append((child.element, next.depth + 1))
            }
        }

        return AccessibleTextExtraction(text: lines.joined(separator: "\n"), truncated: truncated)
    }

    private static let blockRoles: Set<String> = [
        "AXHeading", "AXParagraph", "AXTextArea", "AXTextField", "AXListItem",
    ]

    private static let editorRoles: Set<String> = ["AXTextArea", "AXTextField"]

    private static func containsEditor(_ node: AccessibilityNode) -> Bool {
        editorRoles.contains(node.role) || node.children.contains(where: containsEditor)
    }

    private static func blockText(_ node: AccessibilityNode) -> String? {
        if blockRoles.contains(node.role) {
            if editorRoles.contains(node.role), let raw = node.text {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            var pieces: [String] = []
            collectText(node, into: &pieces)
            let text = pieces.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        guard let raw = node.text else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func collectText(_ node: AccessibilityNode, into pieces: inout [String]) {
        if let raw = node.text {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(text) }
        }
        for child in node.children where !child.isSecure && child.role != "AXSecureTextField" {
            collectText(child, into: &pieces)
        }
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
