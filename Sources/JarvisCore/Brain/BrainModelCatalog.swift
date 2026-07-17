import Foundation

/// The curated brain models the user can pick from, per provider — the single source of truth for
/// the Settings model dropdown and the defaults. Bump a list when a provider ships a new model — a
/// one-line edit. (Transcription models are a separate concern and are NOT listed here.)
public enum BrainModelCatalog {
    /// OpenAI Responses API model ids, confirmed against OpenAI's official model docs (June 2026).
    public static let all: [BrainModel] = [
        BrainModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        BrainModel(id: "gpt-5.4", displayName: "GPT-5.4"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
        BrainModel(id: "gpt-5.4-nano", displayName: "GPT-5.4 nano"),
    ]

    /// The OpenAI model used when nothing is persisted yet — OpenAI's frontier model.
    public static let `default` = all[0]

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }

    /// An empty id means "don't pass a model flag" — the CLI runs whatever its own config selects.
    public static let cliDefault = BrainModel(id: "", displayName: "CLI default")

    /// The pickable models for a provider. CLI lists use the CLIs' *stable aliases* (`sonnet`, not a
    /// dated model id) so the entries survive model releases without a catalog bump.
    public static func models(for provider: BrainProvider) -> [BrainModel] {
        switch provider {
        case .openAI:
            return all
        case .claudeCode:
            return [
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

    /// The model used for a provider when nothing is persisted yet. Claude Code defaults to Sonnet
    /// (predictable latency for a sub-turn coaching loop, regardless of what the CLI's own default
    /// is set to); Codex defaults to the CLI's configured model (see `models(for:)`).
    public static func defaultModel(for provider: BrainProvider) -> BrainModel {
        provider == .openAI ? `default` : models(for: provider)[0]
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
