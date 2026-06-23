import Foundation

/// A failure worth showing the user. The model is Foundation-only and lives in Core so the decision
/// of *how loud* a failure is (alert? stop the session?) is unit-testable; the App-layer `ErrorReporter`
/// only renders it. Construct one at any failure site and hand it to the reporter.
public struct UserFacingError: Error, Sendable, Equatable {
    /// How the reporter should react. `.fatal` interrupts the user and tears the session down;
    /// `.degraded` is a non-blocking notice (the session keeps running); `.info` is log-only.
    public enum Severity: Sendable, Equatable {
        case fatal
        case degraded
        case info

        /// Whether the reporter pops a modal alert for this severity.
        public var showsAlert: Bool { self == .fatal }
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
