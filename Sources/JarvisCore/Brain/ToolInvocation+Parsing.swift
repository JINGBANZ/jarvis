import Foundation

public extension ToolInvocation {
    /// The tool this call names — the inverse of `parse`, and the one place a runner asks "was this
    /// tool offered?" without re-reading the wire call.
    var toolName: String {
        switch self {
        case .captureScreen: captureScreenTool.name
        case .speak: speakToolName
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
        case .speak(let id, _, _): id
        case .searchPrepNotes(let id, _), .loadTool(let id, _), .loadSkill(let id, _): id
        }
    }

    /// Map a wire-level tool call (name + JSON arguments) to a typed invocation — the one place the
    /// coach tool names are interpreted, shared by every brain client. Unknown tool → nil, and the
    /// attempt runner answers the raw call. `speak` is nil unless `lines` decodes to at least one
    /// non-blank string: a strict schema guarantees the shape, but Claude Code's requests
    /// drop `strict`, and a malformed `speak` accepted with empty lines would render an empty overlay
    /// yet still count as a spoken turn.
    static func parse(callId: String, name: String, argumentsJSON: String) -> ToolInvocation? {
        switch name {
        case captureScreenTool.name:
            return .captureScreen(callId: callId)
        case speakToolName:
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let lines = (object?["lines"] as? [String] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { return nil }
            // A session without the box declares no `detail`, so a value here is either that
            // session's own field or a stray one; either way an empty string is no detail.
            let detail = (object?["detail"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .speak(callId: callId, lines: lines,
                          detail: detail.flatMap { $0.isEmpty ? nil : $0 })
        case staySilentTool.name:
            return .staySilent(callId: callId)
        case searchPrepNotesTool.name:
            // A loose object read, not a strict Decodable dictionary: a strict schema guarantees the
            // shape, but a request without `strict` does not, and a sibling field of an unexpected
            // type must not make the whole call fail to parse.
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

}
