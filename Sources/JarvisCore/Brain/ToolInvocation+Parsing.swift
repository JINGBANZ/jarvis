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
            let lines = ((try? JSONDecoder().decode([String: [String]].self,
                                                    from: Data(argumentsJSON.utf8)))?["lines"] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { return nil }
            return .speak(callId: callId, lines: lines)
        case staySilentTool.name:
            return .staySilent(callId: callId)
        default:
            return nil
        }
    }
}
