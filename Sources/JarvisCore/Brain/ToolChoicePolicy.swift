import Foundation

/// `filteredAuto` sends `auto` and declares only the permitted tools: Anthropic has no subset
/// choice, and Claude Fable 5.1 and Opus 5.5 reject forced tool use.
public enum ToolChoicePolicy: String, Sendable, Equatable {
    case providerEnforced
    case filteredAuto
}

public extension ToolChoicePolicy {
    /// Narrowing the declared tools costs the prompt cache from the tools block on, about a second
    /// on OpenAI, so only `filteredAuto` does it.
    func resolve(tools: [ToolDef], choice: ToolChoice) -> (tools: [ToolDef], choice: ToolChoice) {
        guard self == .filteredAuto else { return (tools, choice) }
        switch choice {
        case .allowed(let names): return (tools.filter { names.contains($0.name) }, .auto)
        case .force(let name): return (tools.filter { $0.name == name }, .auto)
        case .auto, .required: return (tools, .auto)
        }
    }
}
