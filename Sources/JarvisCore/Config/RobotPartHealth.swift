import Foundation

/// One part of Jarvis as the Settings hub judges it.
public enum RobotPartHealth: Sendable, Equatable {
    case ready
    /// `reason` is the slot's short upper-case line; `advice` is the page's notice.
    case needsAttention(reason: String, advice: String, fix: Fix?)

    /// A fix Settings can take the user to.
    public enum Fix: Sendable, Equatable {
        case openConnections
    }

    public var isReady: Bool { self == .ready }
}
