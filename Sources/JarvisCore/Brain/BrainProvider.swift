import Foundation

/// Where the brain (coach and summarizer) runs. `openAI` calls the Responses API with the user's API
/// key. The subscription providers send the same Responses requests to the bundled CLIProxyAPI helper
/// on this Mac, which holds the user's ChatGPT or Claude sign-in, so the plan pays for the brain
/// instead of API metering. The CLI providers keep a locally installed coding-agent runtime alive for
/// the Jarvis session.
/// Voice transcription is a separately selected provider; choosing a brain changes only who answers
/// the coaching turns.
public enum BrainProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case codexSubscription = "codex-subscription"
    case claudeSubscription = "claude-subscription"
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI API"
        case .codexSubscription: return "Codex subscription"
        case .claudeSubscription: return "Claude subscription"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        }
    }

    /// The executable a CLI provider is backed by; nil for every HTTP provider.
    public var cliExecutableName: String? {
        switch self {
        case .openAI, .codexSubscription, .claudeSubscription: return nil
        case .claudeCode: return "claude"
        case .codexCLI: return "codex"
        }
    }

    public var usesLocalCLI: Bool { cliExecutableName != nil }

    /// Served by the bundled CLIProxyAPI helper instead of the vendor's own endpoint.
    public var servedByLocalProxy: Bool { proxyModelOwner != nil }

    /// The `owned_by` value in the helper's model list that proves this subscription is signed in:
    /// the helper lists a vendor's models only while it holds a credential for that vendor.
    public var proxyModelOwner: String? {
        switch self {
        case .codexSubscription: return "openai"
        case .claudeSubscription: return "anthropic"
        case .openAI, .claudeCode, .codexCLI: return nil
        }
    }

    /// How this provider's requests carry the permitted set; see `ToolChoicePolicy`. The Claude
    /// subscription cannot be forced: through the helper, a forced tool is a 400 on Claude Fable 5.1
    /// and strips thinking on Opus 5, and a narrowed choice is dropped, so it gets `filteredAuto`.
    public var toolChoicePolicy: ToolChoicePolicy {
        switch self {
        case .claudeSubscription: return .filteredAuto
        case .openAI, .codexSubscription, .claudeCode, .codexCLI: return .providerEnforced
        }
    }

    /// The lowest reasoning effort this provider accepts, raised to without rewriting the user's
    /// shared preference; nil when every level is accepted. `none` disables thinking on the Claude
    /// path, which Claude Fable 5.1 rejects.
    public var reasoningEffortFloor: ReasoningEffort? {
        switch self {
        case .claudeSubscription: return .low
        case .openAI, .codexSubscription, .claudeCode, .codexCLI: return nil
        }
    }
}
