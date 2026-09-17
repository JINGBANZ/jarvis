import Foundation

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
