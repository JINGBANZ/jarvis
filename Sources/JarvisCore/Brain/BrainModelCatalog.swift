import Foundation

public enum BrainModelCatalog {
    public static let all: [BrainModel] = [
        // Rejects `none`.
        BrainModel(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", reasoningEffortFloor: .low),
        // Rejects `none`.
        BrainModel(id: "gpt-6.2-astra", displayName: "GPT-6.2 Astra", reasoningEffortFloor: .low),
        BrainModel(id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra"),
        BrainModel(id: "gpt-6-luna", displayName: "GPT-6 Luna"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
    ]

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }

    private static let claude: [BrainModel] = [
        BrainModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
        BrainModel(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"),
        BrainModel(id: "claude-fable-5-2", displayName: "Claude Fable 5.2"),
        BrainModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5"),
    ]

    // Preview and 2.5 models are left out: the 2.5 family uses a different thinking control.
    private static let gemini: [BrainModel] = [
        BrainModel(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-4-neon", displayName: "Gemini 4 Neon", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-4-carbon", displayName: "Gemini 4 Carbon", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-4-argon", displayName: "Gemini 4 Argon", reasoningEffortFloor: .low),
        BrainModel(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash"),
        BrainModel(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite"),
    ]

    /// OpenAI and Claude list the newest supported release of each model line. Saved IDs outside
    /// the catalog read as unknown. A model Codex doesn't serve fails with `model_not_found`.
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

    /// Empty means the target's own model because Codex does not serve the mini tier.
    public static func summarizerModelID(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI: return "gpt-5.4-mini"
        case .claudeSubscription: return "claude-haiku-5-5"
        case .codexSubscription: return ""
        case .gemini: return "gemini-3.5-flash-lite"
        }
    }
}
