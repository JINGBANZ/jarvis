import Foundation

public enum BrainProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case codexSubscription = "codex-subscription"
    case claudeSubscription = "claude-subscription"
    case gemini = "gemini"

    public var descriptor: BrainProviderDescriptor {
        switch self {
        case .openAI:
            BrainProviderDescriptor(
                displayName: "OpenAI API",
                access: .apiKey(
                    credential: .openAIAPIKey,
                    endpoint: BrainProviderDescriptor.openAIResponsesEndpoint,
                    auth: .bearer),
                wire: .responses,
                failureTable: .openAI,
                toolChoicePolicy: .providerEnforced,
                reasoningEffortFloor: nil)
        // Raw values keep `-subscription`: they are persisted route ids, so renaming them would
        // drop saved routes. The helper answers each route in that API family's own error shape.
        case .codexSubscription:
            BrainProviderDescriptor(
                displayName: "Codex",
                access: .localProxy(
                    modelOwner: "openai", loginFlag: "-codex-login", accountFilePrefix: "codex-"),
                wire: .responses,
                failureTable: .openAI,
                toolChoicePolicy: .providerEnforced,
                reasoningEffortFloor: nil)
        // Anthropic has no subset tool choice and Fable 5.1 and Opus 5.5 reject a forced tool. `none`
        // disables thinking, which they also reject.
        case .claudeSubscription:
            BrainProviderDescriptor(
                displayName: "Claude Code",
                access: .localProxy(
                    modelOwner: "anthropic", loginFlag: "-claude-login", accountFilePrefix: "claude-"),
                wire: .messages,
                failureTable: .anthropic,
                toolChoicePolicy: .filteredAuto,
                reasoningEffortFloor: .low)
        // Called directly, not through the helper: the helper would need the key in its config file
        // and drops Gemini's narrowed tool choice, which Gemini itself honors.
        case .gemini:
            BrainProviderDescriptor(
                displayName: "Gemini API",
                access: .apiKey(
                    credential: .geminiAPIKey,
                    endpoint: BrainProviderDescriptor.geminiInteractionsEndpoint,
                    auth: .googAPIKey),
                wire: .interactions,
                failureTable: .gemini,
                toolChoicePolicy: .providerEnforced,
                reasoningEffortFloor: nil)
        }
    }

    public var displayName: String { descriptor.displayName }

    public var servedByLocalProxy: Bool { descriptor.servedByLocalProxy }

    public var proxyModelOwner: String? {
        if case .localProxy(let owner, _, _) = descriptor.access { owner } else { nil }
    }

    public var credential: Credential? { descriptor.credential }

    public var toolChoicePolicy: ToolChoicePolicy { descriptor.toolChoicePolicy }

    public var reasoningEffortFloor: ReasoningEffort? { descriptor.reasoningEffortFloor }
}
