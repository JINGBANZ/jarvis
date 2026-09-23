import Foundation

public enum BrainModelCatalog {
    public static let all: [BrainModel] = [
        BrainModel(id: "gpt-6-sol", displayName: "GPT-6 Sol"),
        // Rejects `none`.
        BrainModel(id: "gpt-6-astra", displayName: "GPT-6 Astra", reasoningEffortFloor: .low),
        BrainModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
        BrainModel(id: "gpt-6-luna", displayName: "GPT-6 Luna"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
    ]

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }

    private static let claude: [BrainModel] = [
        BrainModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
        BrainModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        BrainModel(id: "claude-fable-5-1", displayName: "Claude Fable 5.1"),
        BrainModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
    ]

    // Preview and 2.5 models are left out: the 2.5 family uses a different thinking control.
    private static let gemini: [BrainModel] = [
        // 3.8 and 3.7 reject `minimal`, which is what `none` becomes.
        BrainModel(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-3.7-flash", displayName: "Gemini 3.7 Flash", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash"),
        BrainModel(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash"),
        BrainModel(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite"),
    ]

    /// Only the newest release of each model line is listed; a saved route naming a dropped one
    /// reads as unknown. A model Codex doesn't serve fails with `model_not_found`.
    /// Invitation-only Mythos releases and rolling aliases are excluded.
    public static func models(for provider: BrainProvider) -> [BrainModel] {
        switch provider {
        case .openAI, .codexSubscription:
            return all
        case .claudeSubscription:
            return claude
        case .gemini:
            return gemini
        }
    }

    public static func defaultModel(for provider: BrainProvider) -> BrainModel {
        models(for: provider).first!
    }

    public static func model(id: String, for provider: BrainProvider) -> BrainModel? {
        models(for: provider).first { $0.id == id }
    }

    /// Empty means the target's own model: Codex serves neither mini model.
    public static func summarizerModelID(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI: return "gpt-5.4-mini"
        case .claudeSubscription: return "claude-haiku-4-5-20251001"
        case .codexSubscription: return ""
        case .gemini: return "gemini-3.5-flash-lite"
        }
    }
}
