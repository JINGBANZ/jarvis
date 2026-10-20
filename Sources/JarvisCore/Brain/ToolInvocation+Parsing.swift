import Foundation

public extension ToolInvocation {
    var toolName: String {
        switch self {
        case .captureScreen: captureScreenTool.name
        case .speak: speakToolName
        case .staySilent: staySilentTool.name
        case .searchReferences: searchReferencesTool.name
        case .readReference: readReferenceTool.name
        case .listReferences: listReferencesTool.name
        case .loadTool: CoachCapabilities.loadToolName
        case .loadSkill: CoachCapabilities.loadSkillName
        }
    }

    var callID: String {
        switch self {
        case .captureScreen(let id), .staySilent(let id): id
        case .speak(let id, _, _), .listReferences(let id, _, _), .searchReferences(let id, _, _): id
        case .readReference(let id, _, _, _): id
        case .loadTool(let id, _), .loadSkill(let id, _): id
        }
    }

    /// Nil for an unknown tool or unusable arguments. Claude Code requests drop `strict`, so
    /// `speak` needs a non-blank hint here or an empty overlay would count as a spoken turn.
    static func parse(callId: String, name: String, argumentsJSON: String) -> ToolInvocation? {
        switch name {
        case captureScreenTool.name:
            return .captureScreen(callId: callId)
        case speakToolName:
            let object = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8))) as? [String: Any]
            let hint = (object?["hint"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty else { return nil }
            let detail = (object?["detail"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .speak(callId: callId, hint: hint,
                          detail: detail.flatMap { $0.isEmpty ? nil : $0 })
        case staySilentTool.name:
            return .staySilent(callId: callId)
        case listReferencesTool.name:
            struct Arguments: Decodable { let query: String?; let cursor: Int? }
            guard argumentsJSON.utf8.count <= 64 * 1024,
                  let args = try? JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8)),
                  args.cursor.map({ $0 >= 0 }) ?? true,
                  args.query.map({ $0.unicodeScalars.count <= 512 }) ?? true else { return nil }
            return .listReferences(callId: callId, query: args.query, cursor: args.cursor)
        case searchReferencesTool.name:
            struct Arguments: Decodable { let query: String; let document_ids: [UUID]? }
            guard argumentsJSON.utf8.count <= 512 * 1024,
                  let args = try? JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8)),
                  !args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  args.query.unicodeScalars.count <= 512, (args.document_ids?.count ?? 0) <= 2000 else { return nil }
            return .searchReferences(callId: callId, query: args.query.trimmingCharacters(in: .whitespacesAndNewlines), documentIDs: args.document_ids)
        case readReferenceTool.name:
            struct Arguments: Decodable { let document_id: UUID; let offset: Int?; let revision_id: String? }
            guard argumentsJSON.utf8.count <= 4096,
                  let args = try? JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8)),
                  (args.offset ?? 0) >= 0, (args.revision_id?.utf8.count ?? 0) <= 256 else { return nil }
            return .readReference(callId: callId, documentID: args.document_id, offset: args.offset ?? 0, revisionID: args.revision_id)
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
