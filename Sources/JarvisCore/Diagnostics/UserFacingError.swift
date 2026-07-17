import Foundation

/// A failure worth showing the user. The model is Foundation-only and lives in Core so the decision
/// of *how loud* a failure is (alert? stop the session?) is unit-testable; the App-layer `ErrorReporter`
/// only renders it. Construct one at any failure site and hand it to the reporter.
public struct UserFacingError: Error, Sendable, Equatable {
    /// How the reporter should react. `.fatal` interrupts the user and tears the session down;
    /// `.warning` interrupts without touching a running session (a *preflight* failure — the thing
    /// that failed never started, so there is nothing to tear down and a live session must survive,
    /// e.g. an in-place restart aborted because the brain CLI vanished); `.degraded` is a
    /// non-blocking notice the session survives (logged, not alerted).
    public enum Severity: Sendable, Equatable {
        case fatal
        case warning
        case degraded

        /// Whether the reporter pops a modal alert for this severity.
        public var showsAlert: Bool { self != .degraded }
        /// Whether the reporter tears down the running session for this severity.
        public var stopsSession: Bool { self == .fatal }
    }

    public let title: String
    public let message: String
    public let severity: Severity

    public init(title: String, message: String, severity: Severity) {
        self.title = title
        self.message = message
        self.severity = severity
    }
}
