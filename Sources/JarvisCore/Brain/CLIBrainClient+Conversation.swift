import Foundation

/// Flattening the client-managed conversation into CLI-ready pieces: ordered segments (text +
/// screenshots), the instruction block, and the prompt-embedded tool protocol.
extension CLIBrainClient {
    /// One ordered piece of the flattened conversation: a labeled text block, or a screenshot in
    /// place. How a screenshot travels is the provider's business (inline block vs `-i` file).
    enum Segment {
        case text(String)
        case imageJPEG(base64: String)
    }

    struct RenderedConversation {
        var system: [String] = []
        var segments: [Segment] = []
    }

    /// Flatten the wire-shaped messages into ordered segments. Assistant tool calls are replayed in
    /// the same JSON protocol the model answers with, so its past actions read exactly like the
    /// actions it can take now.
    func renderConversation(_ messages: [ChatMessage]) -> RenderedConversation {
        var out = RenderedConversation()
        for m in messages {
            switch m.role {
            case .system:
                if let t = m.text { out.system.append(t) }
            case .user:
                if let base64 = m.imageBase64JPEG {
                    out.segments.append(.imageJPEG(base64: base64))
                } else {
                    out.segments.append(.text("[user]\n\(m.text ?? "")"))
                }
            case .assistant:
                if let calls = m.toolCalls {
                    for c in calls {
                        out.segments.append(.text("[assistant]\n{\"tool\":\"\(c.name)\",\"arguments\":\(c.argumentsJSON)}"))
                    }
                } else if let t = m.text {
                    out.segments.append(.text("[assistant]\n\(t)"))
                }
            case .tool:
                out.segments.append(.text("[tool result]\n\(m.text ?? "")"))
            }
        }
        return out
    }

    /// The instruction block: the system text plus the tool protocol. Passed as `--system-prompt`
    /// on Claude Code; prepended to the stdin document on Codex.
    func composeInstructions(system: [String], tools: [ToolDef],
                             toolChoice: ToolChoice) -> String {
        var sections = system
        if !tools.isEmpty { sections.append(composeToolProtocol(tools: tools, toolChoice: toolChoice)) }
        return sections.joined(separator: "\n\n")
    }

    /// The forced-tool sentence for a `.force` turn — appended to the conversation's uncacheable
    /// tail (the "Answer now" trailer) rather than the instructions, which must stay byte-stable.
    static func forcedToolDirective(_ toolChoice: ToolChoice) -> String? {
        guard case .force(let name) = toolChoice else { return nil }
        return "You MUST call the `\(name)` tool this turn."
    }

    /// The CLI-side stand-in for the Responses API's native function calling: the model is told to
    /// end its reply with one JSON object naming the tool. Generated from the same `ToolDef`s the
    /// API client sends, so the two providers stay behaviorally interchangeable.
    private func composeToolProtocol(tools: [ToolDef], toolChoice: ToolChoice) -> String {
        var lines = ["## Tool protocol",
                     "",
                     "You are the decision engine inside an automated harness — your reply is parsed "
                     + "by a program, not read by a person. These are your tools:"]
        for t in tools {
            lines.append("- \(t.name) — \(t.description)")
            lines.append("  arguments JSON Schema: \(t.parametersJSON)")
        }
        lines.append("")
        lines.append("End your reply with a single line containing ONLY this JSON object (no code "
                     + "fence, nothing after it): {\"tool\":\"<tool name>\",\"arguments\":{…}}. "
                     + "Use {} for a tool with no arguments.")
        switch toolChoice {
        case .required, .force:
            // .force gets the SAME instructions as .required — byte-identical instructions keep the
            // provider's prompt cache hot across the whole session (a one-turn forced hint used to
            // rewrite the system prompt and pay two full cache misses). The forced-tool directive
            // rides in the turn's trailer instead (`forcedToolDirective`).
            lines.append("You MUST pick exactly one tool this turn — the JSON object is your entire answer.")
        case .auto:
            lines.append("If no tool fits, reply with plain text instead of the JSON object.")
        }
        return lines.joined(separator: "\n")
    }
}
