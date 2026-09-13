import Foundation

public extension ToolInvocation {
    /// The tool this call names — the inverse of `parse`, and the one place a runner asks "was this
    /// tool offered?" without re-reading the wire call.
    var toolName: String {
        switch self {
        case .captureScreen: captureScreenTool.name
        case .speak: speakTool.name
        case .staySilent: staySilentTool.name
        case .searchPrepNotes: searchPrepNotesTool.name
        case .loadTool: CoachCapabilities.loadToolName
        case .loadSkill: CoachCapabilities.loadSkillName
        }
    }

    /// The id this call must be answered on.
    var callID: String {
        switch self {
        case .captureScreen(let id), .staySilent(let id): id
        case .speak(let id, _, _, _, _): id
        case .searchPrepNotes(let id, _), .loadTool(let id, _), .loadSkill(let id, _): id
        }
    }

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
            return .speak(callId: callId, lines: lines, mermaid: object?["mermaid"] as? String,
                          explanation: detail.flatMap { $0.isEmpty ? nil : $0 },
                          codeSnippet: codeSnippet(from: object?["codeSnippet"]))
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
        case CoachCapabilities.loadToolName, CoachCapabilities.loadSkillName:
            // The literal names, not `ToolDef`s: each loader is composed per Start around the
            // catalog it can offer, so there is no one definition to compare against here.
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let loaded = (object?["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loaded.isEmpty else { return nil }
            return name == CoachCapabilities.loadToolName
                ? .loadTool(callId: callId, name: loaded)
                : .loadSkill(callId: callId, name: loaded)
        default:
            return nil
        }
    }

    /// Only the OpenAI path's strict schema forces `highlightedLines` into every call; the CLI
    /// brains read a prompt-text protocol and naturally omit an empty array when the snippet
    /// corrects nothing. Absent or null therefore means "no highlights", and binding it like the
    /// other members would discard a snippet the model did produce. A present value of the wrong
    /// type stays malformed, so the hint survives on its own.
    private static func codeSnippet(from value: Any?) -> CodeSnippet? {
        guard let value = value as? [String: Any],
              let language = value["language"] as? String,
              let placement = value["placement"] as? String,
              let code = value["code"] as? String else { return nil }
        let raw = value["highlightedLines"] ?? [Int]()
        guard let highlightedLines = raw as? [Int] ?? (raw is NSNull ? [] : nil) else { return nil }
        return CodeSnippet(language: language, placement: placement, code: code,
                           highlightedLines: highlightedLines)
    }
}
