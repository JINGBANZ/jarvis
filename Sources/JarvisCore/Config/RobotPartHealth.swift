import Foundation

public enum RobotPartHealth: Sendable, Equatable {
    case ready
    /// `reason` is the slot's short upper-case line; `advice` is the page's notice.
    case needsAttention(reason: String, advice: String, fix: Fix?)

    public enum Fix: Sendable, Equatable {
        case openConnections
    }

    public var isReady: Bool { self == .ready }
}
