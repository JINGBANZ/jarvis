import Foundation

public struct ActivityResponse: Codable, Equatable, Sendable {
    /// Only a row written before the detail box existed carries one of these.
    public struct Code: Codable, Equatable, Sendable {
        public let language: String
        public let placement: String
        public let code: String
    }

    public let hint: String
    /// Markdown, exactly as delivered.
    public let detail: String?
    // Decoded from older rows.
    public let explanation: String?
    public let code: Code?

    public init(hint: String, detail: String? = nil) {
        self.hint = hint
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = trimmed?.isEmpty == false ? trimmed : nil
        self.explanation = nil
        self.code = nil
    }

    private enum CodingKeys: String, CodingKey {
        case hint, detail, explanation, code
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case lines
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let hint = try values.decodeIfPresent(String.self, forKey: .hint) {
            self.hint = hint
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            hint = try legacy.decode([String].self, forKey: .lines).joined(separator: " ")
        }
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        explanation = try values.decodeIfPresent(String.self, forKey: .explanation)
        code = try values.decodeIfPresent(Code.self, forKey: .code)
    }

    var message: String {
        guard detail != nil || explanation != nil || code != nil else {
            return "💬 \(hint)"
        }
        var parts = ["💬 Hint\n\(hint)"]
        if let detail { parts.append("Detail\n\(detail)") }
        if let explanation { parts.append("Explanation\n\(explanation)") }
        if let code {
            parts.append("Code\n\(code.language)\n\(code.placement)\n\(code.code)")
        }
        return parts.joined(separator: "\n\n")
    }
}
