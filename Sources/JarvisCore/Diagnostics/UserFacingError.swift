import Foundation

/// A failure worth reporting. The model is Foundation-only and lives in Core so the decision of
/// *how loud* a failure is (alert? stop the session?) is unit-testable; the App-layer
/// `ErrorReporter` only applies it. Construct one at any failure site and hand it to the reporter
/// with the context in which it happened.
public struct UserFacingError: Error, Sendable, Equatable {
    /// Where the failure originated. Startup failures may interrupt the explicit Start action;
    /// runtime failures must preserve ghost mode even if their lifecycle consequence stops the
    /// session before the reporter reaches the main actor.
    public enum PresentationContext: Sendable, Equatable {
        case startup
        case runtime
    }

    /// How the reporter should react. `.fatal` tears the session down and permits a startup alert;
    /// `.terminal` tears the session down without activating the app (for ghost-safe failures whose
    /// discreet notice is recorded elsewhere);
    /// `.warning` permits a startup alert without touching a running session (a *preflight* failure — the thing
    /// that failed never started, so there is nothing to tear down and a live session must survive,
    /// e.g. an in-place restart aborted because the brain CLI vanished); `.degraded` is a
    /// non-blocking notice the session survives (logged, not alerted).
    public enum Severity: Sendable, Equatable {
        case fatal
        case terminal
        case warning
        case degraded

        /// Whether the reporter pops a modal alert for this severity.
        public var showsAlert: Bool { self == .fatal || self == .warning }
        /// Whether the reporter tears down the running session for this severity.
        public var stopsSession: Bool { self == .fatal || self == .terminal }

        /// Runtime presentation is forbidden regardless of severity. The context is captured at
        /// the failure site, so teardown cannot race a queued main-actor alert into appearing after
        /// the session has already stopped.
        public func showsAlert(in context: PresentationContext) -> Bool {
            context == .startup && showsAlert
        }
    }

    public let title: String
    public let message: String
    public let severity: Severity
    /// The fixed Activity reason used if this error ends a live session. Raw `message` detail is
    /// intentionally separate and remains available only to the debug log and permitted startup UI.
    public let sessionEndReason: SessionEndReason?

    public init(title: String, message: String, severity: Severity,
                sessionEndReason: SessionEndReason? = nil) {
        self.title = title
        self.message = message
        self.severity = severity
        self.sessionEndReason = sessionEndReason
    }
}
