import Foundation

/// Provider-specific policy shared by the persistent runtime adapters.
extension CLIBrainClient {
    /// Defense in depth for a future Codex app-server that first proves a stable tool-free mode.
    /// This drifting feature intersection is never that proof and cannot authorize a launch.
    static let codexDisabledAgentFeatures = [
        "apps",
        "browser_use",
        "code_mode_host",
        "computer_use",
        "goals",
        "image_generation",
        "multi_agent",
        "plugins",
        "shell_tool",
        "unified_exec",
    ]

    /// App-server `baseInstructions` replaces the coding task with Jarvis's direct decision role.
    static let codexDirectResponseInstruction = """
        Answer this decision request immediately without inspecting files, running commands,
        browsing, planning, delegating, or invoking any Codex built-in tool. The capture_screen,
        speak, and stay_silent names below are an output JSON protocol, not callable Codex tools.
        """

    /// Codex's current catalog starts at `low`; Jarvis's `none` clamps to that floor.
    static func codexEffort(_ effort: String) -> String {
        effort == ReasoningEffort.none.rawValue ? ReasoningEffort.low.rawValue : effort
    }

    /// Claude Code's scale starts at low; Jarvis's `none` therefore clamps to that floor.
    static func claudeEffort(_ effort: String) -> String {
        effort == ReasoningEffort.none.rawValue ? ReasoningEffort.low.rawValue : effort
    }
}
