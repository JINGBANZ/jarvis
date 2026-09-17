import Foundation

public enum BrainProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case codexSubscription = "codex-subscription"
    case claudeSubscription = "claude-subscription"

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
        // drop saved routes. The helper returns each vendor's own error body, in OpenAI's shape.
        case .codexSubscription:
            BrainProviderDescriptor(
                displayName: "Codex",
                access: .localProxy(
                    modelOwner: "openai", loginFlag: "-codex-login", accountFilePrefix: "codex-"),
                wire: .responses,
                failureTable: .openAI,
                toolChoicePolicy: .providerEnforced,
                reasoningEffortFloor: nil)
        // Through the helper, a forced Claude tool is a 400 on Fable 5.1 and strips thinking on
        // Opus 5, and a narrowed choice is dropped. `none` disables thinking, which Fable 5.1
        // rejects.
        case .claudeSubscription:
            BrainProviderDescriptor(
                displayName: "Claude Code",
                access: .localProxy(
                    modelOwner: "anthropic", loginFlag: "-claude-login", accountFilePrefix: "claude-"),
                wire: .responses,
                failureTable: .openAI,
                toolChoicePolicy: .filteredAuto,
                reasoningEffortFloor: .low)
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
