import Foundation

/// A locally installed coding-agent CLI usable as a brain provider — what `AgentCLIDetector` finds.
public struct DetectedAgentCLI: Sendable, Equatable {
    public let provider: BrainProvider
    public let executableURL: URL
    public let authenticationStatus: AgentCLIAuthenticationStatus
    /// Feature names advertised by a Codex CLI's local `features list` command. Empty for Claude or
    /// when the bounded probe is unavailable, so callers never guess flags an installation rejects.
    public let supportedFeatures: Set<String>
    /// Whether bounded local help output confirms the CLI can load an MCP stdio server. False is a
    /// compatibility profile, not a claim that the installed CLI can never support MCP.
    public let supportsMCP: Bool

    public init(provider: BrainProvider, executableURL: URL,
                authenticationStatus: AgentCLIAuthenticationStatus,
                supportedFeatures: Set<String> = [],
                supportsMCP: Bool = false) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticationStatus = authenticationStatus
        self.supportedFeatures = supportedFeatures
        self.supportsMCP = supportsMCP
    }
}
