import Foundation

/// A complete small component, taken from one fenced block in a reply's `detail`. Oversized code is
/// rejected rather than cut into an invalid fragment: half a function coaches nobody.
public struct CodeBlock: Sendable, Equatable {
    /// The fence's info string, lowercased. `text` when the fence named no language, which is what
    /// the box labels it.
    public let language: String
    public let code: String

    /// A `diff` block is how a reply corrects code the candidate wrote: `-` for their line, `+` for
    /// the fix. The box tints and strikes those lines rather than carrying separate indices.
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

    /// The bounds the `coding` skill quotes to the model, so the limit it is told is the limit the
    /// box enforces.
    public static let lineLimit = 24
    public static let characterLimit = 2400
}
