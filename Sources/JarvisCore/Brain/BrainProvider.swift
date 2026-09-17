import Foundation

public enum BrainProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case codexSubscription = "codex-subscription"
    case claudeSubscription = "claude-subscription"

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI API"
        // Raw values keep `-subscription`: they are persisted route ids, so renaming them would
        // drop saved routes.
        case .codexSubscription: return "Codex"
        case .claudeSubscription: return "Claude Code"
        }
    }

    public var servedByLocalProxy: Bool { proxyModelOwner != nil }

    /// The helper lists a vendor's models only while signed in, so this `owned_by` proves sign-in.
    public var proxyModelOwner: String? {
        switch self {
        case .codexSubscription: return "openai"
        case .claudeSubscription: return "anthropic"
        case .openAI: return nil
        }
    }

    /// Through the helper, a forced Claude tool is a 400 on Fable 5.1 and strips thinking on Opus
    /// 5, and a narrowed choice is dropped.
    public var toolChoicePolicy: ToolChoicePolicy {
        switch self {
        case .claudeSubscription: return .filteredAuto
        case .openAI, .codexSubscription: return .providerEnforced
        }
    }

    /// Applied without rewriting the saved preference; nil when every level is accepted. `none`
    /// disables thinking on the Claude path, which Fable 5.1 rejects.
    public var reasoningEffortFloor: ReasoningEffort? {
        switch self {
        case .claudeSubscription: return .low
        case .openAI, .codexSubscription: return nil
        }
    }
}
