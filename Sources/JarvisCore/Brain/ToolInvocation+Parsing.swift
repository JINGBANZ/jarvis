import Foundation

public extension ToolInvocation {
    /// Map a wire-level tool call (name + JSON arguments) to a typed invocation — the one place the
    /// coach tool names are interpreted, shared by every brain client. Unknown tool → nil (callers
    /// log and skip). `speak` is nil unless `lines` decodes to at least one non-blank string: the
    /// API path guarantees the shape via Structured Outputs, but the CLI protocol is prompt text,
    /// and a malformed `speak` accepted with empty lines would render an empty overlay yet still
    /// count as a spoken turn.
    static func parse(callId: String, name: String, argumentsJSON: String) -> ToolInvocation? {
        switch name {
        case captureScreenTool.name:
            return .captureScreen(callId: callId)
        case speakTool.name:
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let lines = (object?["lines"] as? [String] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { return nil }
            let detail = (object?["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet: CodeSnippet?
            if let value = object?["codeSnippet"] as? [String: Any],
               let language = value["language"] as? String,
               let placement = value["placement"] as? String,
               let code = value["code"] as? String,
               let highlightedLines = value["highlightedLines"] as? [Int] {
                snippet = CodeSnippet(language: language, placement: placement, code: code,
                                      highlightedLines: highlightedLines)
            } else {
                snippet = nil
            }
            return .speak(callId: callId, lines: lines, mermaid: object?["mermaid"] as? String,
                          explanation: detail.flatMap { $0.isEmpty ? nil : $0 }, codeSnippet: snippet)
        case staySilentTool.name:
            return .staySilent(callId: callId)
        case searchPrepNotesTool.name:
            // A loose object read, not a strict Decodable dictionary: the API path guarantees the
            // shape via Structured Outputs, but the CLI protocol is free-form prompt text, and a
            // sibling field of an unexpected type must not make the whole call fail to parse.
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let query = (object?["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return nil }
            return .searchPrepNotes(callId: callId, query: query)
        default:
            return nil
        }
    }
}
