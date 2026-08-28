import Foundation
import JarvisCore

/// Flattening the client-managed conversation into CLI-ready pieces: ordered segments (text +
/// screenshots), the instruction block, and the prompt-embedded tool protocol.
extension CLIBrainClient {
    /// One ordered piece of the flattened conversation: a labeled text block, or a screenshot in
    /// place. How a screenshot travels is the provider's business (inline block vs local image).
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
                    out.segments.append(.text(JarvisPrompts.LocalAgent.roleBlock(
                        "user",
                        text: m.text ?? ""
                    )))
                }
            case .assistant:
                if let calls = m.toolCalls {
                    for c in calls {
                        out.segments.append(.text(JarvisPrompts.LocalAgent.assistantToolCall(
                            name: c.name,
                            argumentsJSON: c.argumentsJSON
                        )))
                    }
                } else if let t = m.text {
                    out.segments.append(.text(JarvisPrompts.LocalAgent.roleBlock(
                        "assistant",
                        text: t
                    )))
                }
            case .tool:
                out.segments.append(.text(JarvisPrompts.LocalAgent.roleBlock(
                    "tool result",
                    text: m.text ?? ""
                )))
            }
        }
        return out
    }

    /// The instruction block: the system text plus the tool protocol. Fixed at Claude query startup
    /// and at Codex ephemeral-thread startup so later turns can carry only incremental input.
    static func composeInstructions(system: [String], tools: [ToolDef],
                                    toolChoice: ToolChoice) -> String {
        var sections = system
        if !tools.isEmpty {
            sections.append(JarvisPrompts.LocalAgent.toolProtocol(
                tools: tools,
                toolChoice: toolChoice
            ))
        }
        return sections.joined(separator: "\n\n")
    }
}
