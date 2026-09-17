import Foundation

public struct ActivityResponse: Codable, Equatable, Sendable {
    /// Only a row written before the detail box existed carries one of these.
    public struct Code: Codable, Equatable, Sendable {
        public let language: String
        public let placement: String
        public let code: String
    }

    public let lines: [String]
    /// Markdown, exactly as delivered.
    public let detail: String?
    // Decoded from older rows. No initial value on purpose: synthesized `Decodable` skips a `let`
    // with a default, so every old row would decode as nil.
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
