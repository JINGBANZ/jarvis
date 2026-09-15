import Foundation
import JarvisCore

/// Provider-specific policy shared by the persistent runtime adapters.
extension CLIBrainClient {
    /// Defense in depth for a future Codex app-server that first proves a stable tool-free mode.
    /// This drifting feature intersection is never that proof and cannot authorize a launch.
    ///
    /// The shell snapshots are listed for privacy, not tools: with them on, Codex dumps the login
    /// shell's exported environment, secrets included, into the runtime home.
    static let codexDisabledAgentFeatures = [
        "apps",
        "browser_use",
        "code_mode_host",
        "computer_use",
        "goals",
        "image_generation",
        "multi_agent",
        "plugins",
        "shell_snapshot",
        "shell_snapshot_v2",
        "shell_tool",
        "unified_exec",
    ]

    /// Codex's current catalog starts at `low`; Jarvis's `none` clamps to that floor.
    static func codexEffort(_ effort: String) -> String {
        effort == ReasoningEffort.none.rawValue ? ReasoningEffort.low.rawValue : effort
    }

    /// Claude Code's scale starts at low; Jarvis's `none` therefore clamps to that floor.
    static func claudeEffort(_ effort: String) -> String {
        effort == ReasoningEffort.none.rawValue ? ReasoningEffort.low.rawValue : effort
    }
}
