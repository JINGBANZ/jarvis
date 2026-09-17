import Foundation
import JarvisCore

/// `unknown` keeps a failed or timed-out status probe from becoming a false logout claim.
public enum AgentCLIAuthenticationStatus: Sendable, Equatable {
    case signedIn
    case signedOut
    case unknown
}
