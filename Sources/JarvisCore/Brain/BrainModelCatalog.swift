import Foundation

/// The curated brain models the user can pick from, per provider — the single source of truth for
/// the Settings model dropdown and the defaults. Bump a list when a provider ships a new model — a
/// one-line edit. (Transcription models are a separate concern and are NOT listed here.)
public enum BrainModelCatalog {
    /// The six current OpenAI model ids shared by the Responses API and Codex CLI pickers,
    /// confirmed against OpenAI's official model docs (July 2026).
    public static let all: [BrainModel] = [
        BrainModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
        BrainModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
        BrainModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
        BrainModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        BrainModel(id: "gpt-5.4", displayName: "GPT-5.4"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
    ]

    /// Adding picker choices must not silently change the model for a user with no saved override.
    public static let `default` = all.first { $0.id == "gpt-5.5" }!

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }

    /// Concrete models per provider. OpenAI API and Codex CLI intentionally share one list.
    /// Claude exposes only the newest release in each family; invitation-only Mythos releases and
    /// rolling aliases are excluded.
    public static func models(for provider: BrainProvider) -> [BrainModel] {
        switch provider {
        case .openAI, .codexCLI:
            return all
        case .claudeCode:
            return [
                BrainModel(id: "claude-opus-5", displayName: "Claude Opus 5"),
                BrainModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
                BrainModel(id: "claude-fable-5", displayName: "Claude Fable 5"),
                BrainModel(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
            ]
        }
    }

    /// The model used for a provider when nothing is persisted yet. Claude keeps the Sonnet tier's
    /// predictable latency; Codex uses the official default Power model.
    public static func defaultModel(for provider: BrainProvider) -> BrainModel {
        switch provider {
        case .openAI:
            return `default`
        case .claudeCode:
            return model(id: "claude-sonnet-5", for: provider)!
        case .codexCLI:
            return model(id: "gpt-5.6-sol", for: provider)!
        }
    }

    public static func model(id: String, for provider: BrainProvider) -> BrainModel? {
        models(for: provider).first { $0.id == id }
    }

    /// The cheap model each provider uses for history-compaction summaries — text-only briefings a
    /// few times an hour, so the smallest adequate tier.
    public static func summarizerModelID(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI: return "gpt-5.4-mini"
        case .claudeCode: return "claude-haiku-4-5"
        case .codexCLI: return "gpt-5.4-mini"
        }
    }
}
