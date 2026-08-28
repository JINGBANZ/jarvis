import Foundation
import JarvisCore

/// What Jarvis can establish about a detected local brain CLI's current sign-in state.
/// `unknown` is distinct from signed out so a failed or timed-out status probe never becomes a
/// false logout claim.
public enum AgentCLIAuthenticationStatus: Sendable, Equatable {
    case signedIn
    case signedOut
    case unknown
}
