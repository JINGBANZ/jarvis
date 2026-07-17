import Foundation

/// A locally installed coding-agent CLI usable as a brain provider — what `AgentCLIDetector` finds.
public struct DetectedAgentCLI: Sendable, Equatable {
    public let provider: BrainProvider
    public let executableURL: URL
    /// Best-effort "signed in" check from the CLI's on-disk auth markers. A false negative is
    /// possible (e.g. Claude Code storing credentials only in the Keychain), so callers should treat
    /// this as a hint for the UI, never as a hard gate.
    public let authenticated: Bool

    public init(provider: BrainProvider, executableURL: URL, authenticated: Bool) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticated = authenticated
    }
}
