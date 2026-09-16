import Foundation

/// A coding-agent CLI the session evaluator can run: the one place the evaluator, `EvalPrep`, and the
/// detector name a binary. Coaching never runs one; the subscription targets reach the same accounts
/// through the bundled helper instead.
public enum AgentCLI: String, CaseIterable, Sendable {
    case claude
    case codex

    public var executableName: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}
