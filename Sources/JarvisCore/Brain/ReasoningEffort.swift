import Foundation

/// How hard the brain model thinks before answering, passed to the Responses API as
/// `reasoning.effort`. One global setting applied to whichever `BrainModel` is selected — the four
/// levels below are shared across every selectable OpenAI, Claude Code, and Codex CLI model. CLI
/// adapters clamp only when a provider has a higher floor. Lower effort favors speed and fewer
/// tokens; higher effort thinks more completely. `rawValue` is the exact API string.
public enum ReasoningEffort: String, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high

    /// Title-case label for the settings picker.
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// `low` keeps a coaching turn fast (sub-2s target) while still allowing tool calls.
    public static let `default`: ReasoningEffort = .low

    /// The combined `max_output_tokens` budget to pair with this effort. On the Responses API this
    /// cap covers reasoning + visible output + formatting tokens *together*, so it must clear the
    /// whole reasoning pass before any tip is emitted — otherwise the run comes back
    /// `status:"incomplete"` with reason `max_output_tokens` and zero output (what a flat 768 did at
    /// `high`). These are runaway guards set well above expected consumption and scaled with effort;
    /// `high` matches OpenAI's recommended ≥25k reserve for reasoning + outputs. The visible tip
    /// itself is only ~100–200 tokens, so the budget is almost entirely reasoning headroom. Tune
    /// down using the per-turn reasoning-token usage the brain client logs.
    public var maxOutputTokens: Int {
        switch self {
        case .none: return 1_024
        case .low: return 2_048
        case .medium: return 8_192
        case .high: return 25_000
        }
    }
}
