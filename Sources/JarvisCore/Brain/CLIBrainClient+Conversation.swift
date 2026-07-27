import Foundation

/// Flattening the client-managed conversation into CLI-ready pieces: ordered segments (text +
/// screenshots) and the instruction block.
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

    /// Flatten the wire-shaped messages into ordered segments. Historical assistant tool calls are
    /// serialized so tool-less auxiliary calls can understand the conversation they summarize.
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

    /// The forced-tool sentence for a `.force` turn — appended to the conversation's uncacheable
    /// tail (the "Answer now" trailer) rather than the instructions, which must stay byte-stable.
    static func forcedToolDirective(_ toolChoice: ToolChoice) -> String? {
        guard case .force(let name) = toolChoice else { return nil }
        return "You MUST call the `\(name)` tool this turn."
    }

}
