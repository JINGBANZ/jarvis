import Foundation

public struct DetectedAgentCLI: Sendable, Equatable {
    public let cli: AgentCLI
    public let executableURL: URL
    public let authenticationStatus: AgentCLIAuthenticationStatus

    public init(cli: AgentCLI, executableURL: URL, authenticationStatus: AgentCLIAuthenticationStatus) {
        self.cli = cli
        self.executableURL = executableURL
        self.authenticationStatus = authenticationStatus
    }
}
