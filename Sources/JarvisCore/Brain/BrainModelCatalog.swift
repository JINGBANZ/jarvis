import Foundation

/// The curated brain models the user can pick from, per provider — the single source of truth for
/// the Settings model dropdown and the defaults. Bump a list when a provider ships a new model — a
/// one-line edit. (Transcription models are a separate concern and are NOT listed here.)
public enum BrainModelCatalog {
    /// OpenAI Responses API model ids, confirmed against OpenAI's official model docs (July 2026).
    /// The first six are the newest releases. GPT-5.4 remains selectable so an existing saved
    /// preference does not silently change models when the catalog grows.
    public static let all: [BrainModel] = [
        BrainModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
        BrainModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
        BrainModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
        BrainModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
        BrainModel(id: "gpt-5.4-nano", displayName: "GPT-5.4 nano"),
        BrainModel(id: "gpt-5.4", displayName: "GPT-5.4"),
    ]

    /// Adding picker choices must not silently change the model for a user with no saved override.
    public static let `default` = all.first { $0.id == "gpt-5.5" }!

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }

    /// An empty id means "don't pass a model flag" — the CLI runs whatever its own config selects.
    public static let cliDefault = BrainModel(id: "", displayName: "CLI default")

    /// The pickable models for a provider. Claude's six newest generally available releases use
    /// pinned ids; its rolling aliases remain available for existing preferences and users who want
    /// automatic upgrades. Invitation-only Mythos releases are deliberately excluded.
    public static func models(for provider: BrainProvider) -> [BrainModel] {
        switch provider {
        case .openAI:
            return all
        case .claudeCode:
            return [
                BrainModel(id: "claude-opus-5", displayName: "Claude Opus 5"),
                BrainModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
                BrainModel(id: "claude-fable-5", displayName: "Claude Fable 5"),
                BrainModel(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
                BrainModel(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
                BrainModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
                BrainModel(id: "sonnet", displayName: "Sonnet (latest)"),
                BrainModel(id: "opus", displayName: "Opus (latest)"),
                BrainModel(id: "haiku", displayName: "Haiku (latest)"),
                cliDefault,
            ]
        case .codexCLI:
            // Codex model naming shifts release to release, so the robust default is the CLI's own
            // configured model; the explicit ids match what codex-cli 0.144 actually offers
            // (verified July 2026) — adjust alongside codex releases.
            return [
                cliDefault,
                BrainModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                BrainModel(id: "gpt-5.5", displayName: "GPT-5.5"),
            ]
        }
    }

    /// The model used for a provider when nothing is persisted yet. Claude Code keeps its rolling
    /// Sonnet default (predictable latency for a sub-turn coaching loop); adding pinned releases
    /// must not silently move it to the first, newest catalog entry. Codex uses its CLI default.
    public static func defaultModel(for provider: BrainProvider) -> BrainModel {
        switch provider {
        case .openAI:
            return `default`
        case .claudeCode:
            return model(id: "sonnet", for: provider)!
        case .codexCLI:
            return cliDefault
        }
    }

    public static func model(id: String, for provider: BrainProvider) -> BrainModel? {
        models(for: provider).first { $0.id == id }
    }

    /// The cheap model each provider uses for history-compaction summaries — text-only briefings a
    /// few times an hour, so the smallest adequate tier. Codex has no separately-priced small alias,
    /// so it stays on the CLI's default.
    public static func summarizerModelID(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI: return "gpt-5.4-mini"
        case .claudeCode: return "haiku"
        case .codexCLI: return ""
        }
    }
}
