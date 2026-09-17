import Foundation

public enum BrainModelCatalog {
    public static let all: [BrainModel] = [
        BrainModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
        BrainModel(id: "gpt-6-astra", displayName: "GPT-6 Astra"),
        BrainModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
        BrainModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
        BrainModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        BrainModel(id: "gpt-5.4", displayName: "GPT-5.4"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
    ]

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }

    private static let claude: [BrainModel] = [
        BrainModel(id: "claude-opus-5", displayName: "Claude Opus 5"),
        BrainModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        BrainModel(id: "claude-fable-5-1", displayName: "Claude Fable 5.1"),
        BrainModel(id: "claude-fable-5", displayName: "Claude Fable 5"),
        BrainModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
    ]

    /// Older releases stay listed so saved routes stay valid; a model Codex doesn't serve fails
    /// with `model_not_found`. Invitation-only Mythos releases and rolling aliases are excluded.
    public static func models(for provider: BrainProvider) -> [BrainModel] {
        switch provider {
        case .openAI, .codexSubscription:
            return all
        case .claudeSubscription:
            return claude
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
        }
    }
}
