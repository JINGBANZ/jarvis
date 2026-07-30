import Foundation

/// Where the brain (coach/summarizer/evaluator) runs. `openAI` calls the Responses API with the
/// user's API key; the CLI providers keep a locally installed coding-agent runtime alive for the
/// Jarvis session, so the user's existing Claude / ChatGPT *subscription* pays for the brain instead
/// of API metering.
/// Voice transcription is a separately selected provider; choosing a brain changes only who answers
/// the coaching turns.
public enum BrainProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI API"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        }
    }

    /// The executable a CLI provider is backed by; nil for the direct-API provider.
    public var cliExecutableName: String? {
        switch self {
        case .openAI: return nil
        case .claudeCode: return "claude"
        case .codexCLI: return "codex"
        }
    }

    public var usesLocalCLI: Bool { cliExecutableName != nil }
}
