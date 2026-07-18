import Foundation

/// A locally installed coding-agent CLI usable as a brain provider — what `AgentCLIDetector` finds.
public struct DetectedAgentCLI: Sendable, Equatable {
    public let provider: BrainProvider
    public let executableURL: URL
    public let authenticationStatus: AgentCLIAuthenticationStatus

    public init(provider: BrainProvider, executableURL: URL,
                authenticationStatus: AgentCLIAuthenticationStatus) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticationStatus = authenticationStatus
    }
}
