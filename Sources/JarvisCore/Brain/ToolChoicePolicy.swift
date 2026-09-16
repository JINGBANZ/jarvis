import Foundation

/// How a target receives a request's permitted set. `providerEnforced` sends `required`,
/// `allowed_tools`, and a forced function, and trusts the provider to honor them. `filteredAuto`
/// sends `tool_choice: auto` and declares only the permitted tools, for a provider that cannot force
/// or narrow a call: Anthropic offers no subset choice, and Claude Fable 5.1 rejects forced tool use.
/// Either way `CoachAttemptRunner` checks the reply against the choice it asked for.
public enum ToolChoicePolicy: String, Sendable, Equatable {
    case providerEnforced
    case filteredAuto
}
