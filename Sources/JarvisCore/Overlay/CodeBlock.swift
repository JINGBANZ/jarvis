import Foundation

/// Oversized code is rejected, never truncated: half a function coaches nobody.
public struct CodeBlock: Sendable, Equatable {
    /// Lowercased; `text` when the fence named none.
    public let language: String
    public let code: String

    public var isDiff: Bool { language == "diff" }

    public init?(language: String, code: String) {
        let lineNormalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        // Reject other rendered line separators rather than rewriting possible string-literal content.
        guard lineNormalized.allSatisfy({ !$0.isNewline || $0 == "\n" }) else { return nil }
        let normalized = lineNormalized.trimmingCharacters(in: .newlines)
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lineCount = normalized.components(separatedBy: "\n").count
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.count <= Self.characterLimit, lineCount <= Self.lineLimit,
              language.count <= 40,
              !language.contains(where: { $0.isNewline || $0.isWhitespace }) else { return nil }
        self.language = language.isEmpty ? "text" : language
        self.code = normalized
    }

    /// The `coding` skill's SKILL.md quotes these limits; change both together.
    public static let lineLimit = 24
    public static let characterLimit = 2400
}
