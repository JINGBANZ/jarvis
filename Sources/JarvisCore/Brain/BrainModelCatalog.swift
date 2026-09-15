import Foundation

/// The curated brain models the user can pick from, per provider — the single source of truth for
/// the Settings model dropdown and the defaults. Bump a list when a provider ships a new model — a
/// one-line edit. (Transcription models are a separate concern and are NOT listed here.)
public enum BrainModelCatalog {
    /// The curated OpenAI model ids shared by the Responses API and Codex CLI pickers,
    /// confirmed against OpenAI's official model docs (September 2026).
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

    /// The curated Claude model ids shared by every Claude provider.
    private static let claude: [BrainModel] = [
        BrainModel(id: "claude-opus-5", displayName: "Claude Opus 5"),
        BrainModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        BrainModel(id: "claude-fable-5-1", displayName: "Claude Fable 5.1"),
        BrainModel(id: "claude-fable-5", displayName: "Claude Fable 5"),
        BrainModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5"),
    ]

    /// Concrete models per provider. Every OpenAI-family provider intentionally shares one list, and
    /// every Claude provider the other. Older concrete releases remain selectable so catalog
    /// additions do not invalidate saved routes; one the Codex subscription does not serve fails at
    /// request time with the helper's `model_not_found`. Invitation-only Mythos releases and rolling
    /// aliases are excluded.
    public static func models(for provider: BrainProvider) -> [BrainModel] {
        switch provider {
        case .openAI, .codexSubscription, .codexCLI:
            return all
        case .claudeSubscription, .claudeCode:
            return claude
        }
    }

    /// The first curated model is the provider default when nothing valid is persisted.
    public static func defaultModel(for provider: BrainProvider) -> BrainModel {
        models(for: provider).first!
    }

    public static func model(id: String, for provider: BrainProvider) -> BrainModel? {
        models(for: provider).first { $0.id == id }
    }

    /// The cheap verified model each provider uses for history-compaction summaries. Empty means
    /// the target's own model: the Codex subscription serves neither mini model, and the Codex CLI
    /// omits a model override until a separate cheaper CLI model id is verified.
    public static func summarizerModelID(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI: return "gpt-5.4-mini"
        case .claudeSubscription, .claudeCode: return "claude-haiku-4-5-20251001"
        case .codexSubscription, .codexCLI: return ""
        }
    }
}
