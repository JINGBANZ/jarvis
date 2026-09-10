import Foundation

/// The delivered parts of one coaching response, retained separately for live Activity, history,
/// and export. The plain message remains readable by older builds and evidence consumers.
public struct ActivityResponse: Codable, Equatable, Sendable {
    public struct Code: Codable, Equatable, Sendable {
        public let language: String
        public let placement: String
        public let code: String
    }

    public let lines: [String]
    public let explanation: String?
    public let code: Code?

    public init(lines: [String], explanation: String? = nil, codeSnippet: CodeSnippet? = nil) {
        self.lines = lines
        let detail = explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.explanation = detail?.isEmpty == false ? detail : nil
        code = codeSnippet.map { Code(language: $0.language, placement: $0.placement, code: $0.code) }
    }

    var message: String {
        guard explanation != nil || code != nil else { return "💬 \(lines.joined(separator: " "))" }
        var parts = ["💬 Hint\n\(lines.joined(separator: "\n"))"]
        if let explanation { parts.append("Explanation\n\(explanation)") }
        if let code {
            parts.append("Code\n\(code.language)\n\(code.placement)\n\(code.code)")
        }
        return parts.joined(separator: "\n\n")
    }
}
