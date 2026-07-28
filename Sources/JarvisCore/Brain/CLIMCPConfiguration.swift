import Foundation

/// Public, secret-free description of one attempt's lease on the private MCP session bridge.
///
/// The ticket path and its contents are unique to one attempt; the file is owner-only and removed
/// when the lease ends. Only its path travels in argv or provider config, keeping the bearer itself
/// out of process listings and traffic records.
public struct CLIMCPConfiguration: Sendable, Equatable {
    public let serverName: String
    public let serverExecutable: URL
    public let ticketFile: URL
    /// Claude receives a per-attempt JSON file pointing to that attempt's ticket. Codex receives the
    /// same request-derived server configuration through command-line overrides and keeps this nil.
    public let claudeConfigFile: URL?

    public init(
        serverName: String = "jarvis",
        serverExecutable: URL,
        ticketFile: URL,
        claudeConfigFile: URL?
    ) {
        self.serverName = serverName
        self.serverExecutable = serverExecutable
        self.ticketFile = ticketFile
        self.claudeConfigFile = claudeConfigFile
    }
}
