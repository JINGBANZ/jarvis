import Foundation

/// Public, secret-free description of the private MCP sidecar for one CLI coaching attempt.
///
/// The ticket file contains the bearer secret and is owner-only. Only its path travels in argv or
/// provider config, keeping the secret itself out of process listings and traffic records.
public struct CLIMCPConfiguration: Sendable, Equatable {
    public let serverName: String
    public let serverExecutable: URL
    public let ticketFile: URL
    public let claudeConfigFile: URL

    public init(
        serverName: String = "jarvis",
        serverExecutable: URL,
        ticketFile: URL,
        claudeConfigFile: URL
    ) {
        self.serverName = serverName
        self.serverExecutable = serverExecutable
        self.ticketFile = ticketFile
        self.claudeConfigFile = claudeConfigFile
    }
}
