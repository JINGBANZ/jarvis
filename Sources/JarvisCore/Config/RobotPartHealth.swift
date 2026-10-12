import Foundation

public enum RobotPartHealth: Sendable, Equatable {
    case ready
    case checking
    /// `reason` is the slot's short upper-case line; `advice` is the page's notice.
    case needsAttention(reason: String, advice: String, fix: Fix?)
    case blocked(reason: String, advice: String, fix: Fix?)

    public enum Fix: Sendable, Equatable {
        case openConnections
    }

    public var isReady: Bool { self == .ready }

    public var tone: RobotSlotState.Tone {
        switch self {
        case .ready: .normal
        case .checking, .needsAttention: .attention
        case .blocked: .blocked
        }
    }

    public var reason: String? {
        switch self {
        case .ready: nil
        case .checking: "CHECKING CONNECTIONS"
        case .needsAttention(let reason, _, _), .blocked(let reason, _, _): reason
        }
    }

    public var advice: String? {
        switch self {
        case .ready, .checking: nil
        case .needsAttention(_, let advice, _), .blocked(_, let advice, _): advice
        }
    }

    public var fix: Fix? {
        switch self {
        case .ready, .checking: nil
        case .needsAttention(_, _, let fix), .blocked(_, _, let fix): fix
        }
    }
}
