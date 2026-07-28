import Foundation

/// A locally installed coding-agent CLI usable as a brain provider — what `AgentCLIDetector` finds.
public struct DetectedAgentCLI: Sendable, Equatable {
    public let provider: BrainProvider
    public let executableURL: URL
    public let authenticationStatus: AgentCLIAuthenticationStatus
    /// Enabled, non-removed feature names reported by this Codex installation. Jarvis passes these
    /// exact names back as per-invocation `--disable` flags, so new tool surfaces default off without
    /// guessing version-specific identifiers. Empty for Claude and when the bounded probe fails.
    public let codexFeaturesToDisable: Set<String>
    /// Whether bounded local help output proves the CLI can load Jarvis's constrained MCP action
    /// surface. A false value makes this installation unavailable for coaching.
    public let supportsMCP: Bool

    public init(provider: BrainProvider, executableURL: URL,
                authenticationStatus: AgentCLIAuthenticationStatus,
                codexFeaturesToDisable: Set<String> = [],
                supportsMCP: Bool = false) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticationStatus = authenticationStatus
        self.codexFeaturesToDisable = codexFeaturesToDisable
        self.supportsMCP = supportsMCP
    }
}
