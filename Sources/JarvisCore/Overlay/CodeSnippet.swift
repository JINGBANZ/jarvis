import Foundation

/// A complete small component. Oversized code is rejected rather than cut into an invalid fragment.
public struct CodeSnippet: Sendable, Equatable {
    public let language: String
    public let placement: String
    public let code: String
    /// One-based snippet line indices, independent of the editor's line numbers.
    public let highlightedLines: [Int]

    public init?(language: String, placement: String, code: String, highlightedLines: [Int] = []) {
        guard highlightedLines.count <= 12 else { return nil }
        let lineNormalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        // Reject other rendered line separators rather than rewriting possible string-literal content.
        guard lineNormalized.allSatisfy({ !$0.isNewline || $0 == "\n" }) else { return nil }
        let droppedLeading = lineNormalized.prefix { $0 == "\n" }.count
        let normalized = lineNormalized.trimmingCharacters(in: .newlines)
        let placement = placement.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = normalized.components(separatedBy: "\n").count
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.count <= 2400, lineCount <= 12,
              !placement.isEmpty, placement.count <= 160, language.count <= 40,
              !placement.contains(where: { $0.isNewline }),
              !language.contains(where: { $0.isNewline }) else { return nil }
        self.language = language
        self.placement = placement
        self.code = normalized
        self.highlightedLines = Array(Set(highlightedLines.compactMap { index in
            // Check bounds before subtraction, including malformed Int.min/Int.max indices.
            guard index > droppedLeading, index <= droppedLeading + lineCount else { return nil }
            return index - droppedLeading
        })).sorted()
    }
}
