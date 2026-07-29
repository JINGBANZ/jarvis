import Foundation

/// A locally installed coding-agent CLI and the capabilities `AgentCLIDetector` can establish.
public struct DetectedAgentCLI: Sendable, Equatable {
    public static let codexToolFreeModeUnavailableDetail =
        "Codex CLI app-server does not expose a stable mode that removes every built-in tool"

    public enum CoachingIsolation: Sendable, Equatable {
        /// The provider exposes a documented launch mode with no inherited customizations or
        /// callable built-in agent tools.
        case toolFree
        /// This CLI may be installed and signed in, but its current provider surface cannot satisfy
        /// Jarvis's decision-only boundary.
        case toolFreeModeUnavailable
    }

    public let provider: BrainProvider
    public let executableURL: URL
    public let authenticationStatus: AgentCLIAuthenticationStatus
    /// Feature names advertised by a Codex CLI's local `features list` command. Empty for Claude or
    /// when the bounded probe is unavailable, so callers never guess flags an installation rejects.
    public let supportedFeatures: Set<String>
    /// Capability discovery must never weaken this boundary. Codex 0.145 app-server has no stable
    /// empty-tools field; its feature list can only disable known families and therefore cannot
    /// prove absence as the catalog grows.
    public var coachingIsolation: CoachingIsolation {
        provider == .codexCLI ? .toolFreeModeUnavailable : .toolFree
    }

    public init(provider: BrainProvider, executableURL: URL,
                authenticationStatus: AgentCLIAuthenticationStatus,
                supportedFeatures: Set<String> = []) {
        self.provider = provider
        self.executableURL = executableURL
        self.authenticationStatus = authenticationStatus
        self.supportedFeatures = supportedFeatures
    }
}
