import Foundation

/// A locally installed coding-agent CLI usable as a brain provider — what `AgentCLIDetector` finds.
public struct DetectedAgentCLI: Sendable, Equatable {
    public let provider: BrainProvider
    public let executableURL: URL
    public let authenticationStatus: AgentCLIAuthenticationStatus
    /// Feature names advertised by a Codex CLI's local `features list` command. Empty for Claude or
    /// when the bounded probe is unavailable, so callers never guess flags an installation rejects.
    public let supportedFeatures: Set<String>

    public init(provider: BrainProvider, executableURL: URL,
                authenticationStatus: AgentCLIAuthenticationStatus,
                supportedFeatures: Set<String> = []) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticationStatus = authenticationStatus
        self.supportedFeatures = supportedFeatures
    }
}
