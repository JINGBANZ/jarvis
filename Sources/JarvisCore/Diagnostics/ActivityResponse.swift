import Foundation

/// The delivered parts of one coaching response, retained separately for live Activity, history,
/// and export. The plain message remains readable by older builds and evidence consumers.
public struct ActivityResponse: Codable, Equatable, Sendable {
    /// Only a row written before the detail box existed carries one of these.
    public struct Code: Codable, Equatable, Sendable {
        public let language: String
        public let placement: String
        public let code: String
    }

    public let lines: [String]
    /// The detail box's Markdown, exactly as it was delivered.
    public let detail: String?
    // Read back from rows written before this change, so a past session still opens with the
    // sections it was recorded with. Declared without an initial value on purpose: a `let` with a
    // default is excluded from the synthesized `Decodable`, and every old row would decode as nil.
    public let explanation: String?
    public let code: Code?

    public init(lines: [String], detail: String? = nil) {
        self.lines = lines
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = trimmed?.isEmpty == false ? trimmed : nil
        self.explanation = nil
        self.code = nil
    }

    var message: String {
        guard detail != nil || explanation != nil || code != nil else {
            return "💬 \(lines.joined(separator: " "))"
        }
        var parts = ["💬 Hint\n\(lines.joined(separator: "\n"))"]
        if let detail { parts.append("Detail\n\(detail)") }
        if let explanation { parts.append("Explanation\n\(explanation)") }
        if let code {
            parts.append("Code\n\(code.language)\n\(code.placement)\n\(code.code)")
        }
        return parts.joined(separator: "\n\n")
    }
}
