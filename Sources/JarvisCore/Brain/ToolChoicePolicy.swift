import Foundation

/// `filteredAuto` sends `auto` and declares only the permitted tools: Anthropic has no subset
/// choice, and Claude Fable 5.1 rejects forced tool use.
public enum ToolChoicePolicy: String, Sendable, Equatable {
    case providerEnforced
    case filteredAuto
}
