import Foundation

public extension ToolInvocation {
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

    var callID: String {
        switch self {
        case .captureScreen(let id), .staySilent(let id): id
        case .speak(let id, _, _): id
        case .searchPrepNotes(let id, _), .loadTool(let id, _), .loadSkill(let id, _): id
        }
    }

    /// Nil for an unknown tool or unusable arguments. Claude Code requests drop `strict`, so
    /// `speak` needs a non-blank line here or an empty overlay would count as a spoken turn.
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
            let detail = (object?["detail"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .speak(callId: callId, lines: lines,
                          detail: detail.flatMap { $0.isEmpty ? nil : $0 })
        case staySilentTool.name:
            return .staySilent(callId: callId)
        case searchPrepNotesTool.name:
            // Loose read: without `strict`, an oddly typed sibling field must not fail the call.
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let query = (object?["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return nil }
            return .searchPrepNotes(callId: callId, query: query)
        case CoachCapabilities.loadToolName, CoachCapabilities.loadSkillName:
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let loaded = (object?["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loaded.isEmpty else { return nil }
            return name == CoachCapabilities.loadToolName
                ? .loadTool(callId: callId, name: loaded)
                : .loadSkill(callId: callId, name: loaded)
        case CoachCapabilities.callToolName:
            // The routed tool parses exactly as a direct call would. A fixed tool is refused here,
            // so a press cannot reach capture_screen through the dispatcher.
            guard let target = routedToolName(argumentsJSON: argumentsJSON),
                  !CoachCapabilities.fixedToolNames.contains(target) else { return nil }
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let routed: String
            if let text = object?["arguments"] as? String {
                routed = text
            } else if let nested = object?["arguments"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys]) {
                routed = String(decoding: data, as: UTF8.self)
            } else {
                return nil
            }
            return parse(callId: callId, name: target, argumentsJSON: routed)
        default:
            return nil
        }
    }

    /// The `name` a `call_tool` call routes to, read on its own so a malformed routed call can be
    /// answered with the routed tool's schema.
    static func routedToolName(argumentsJSON: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8))) as? [String: Any]
        let name = (object?["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

}
