import Foundation

public struct UserFacingError: Error, Sendable, Equatable {
    public enum PresentationContext: Sendable, Equatable {
        case startup
        case runtime
    }

    public enum Severity: Sendable, Equatable {
        case fatal
        case terminal
        /// A preflight failure: nothing started, so a live session must survive it.
        case warning
        case degraded

        public var showsAlert: Bool { self == .fatal || self == .warning }
        public var stopsSession: Bool { self == .fatal || self == .terminal }

        /// Runtime presentation is always forbidden. The context is captured at the failure site,
        /// so teardown cannot race a queued alert into appearing after the session stopped.
        public func showsAlert(in context: PresentationContext) -> Bool {
            context == .startup && showsAlert
        }
    }

    public let title: String
    public let message: String
    public let severity: Severity
    /// Activity shows this fixed reason; raw `message` goes only to the debug log and startup UI.
    public let sessionEndReason: SessionEndReason?

    public init(title: String, message: String, severity: Severity,
                sessionEndReason: SessionEndReason? = nil) {
        self.title = title
        self.message = message
        self.severity = severity
        self.sessionEndReason = sessionEndReason
    }
}
