import Foundation

/// Holds only the message and date: formatting and I/O run on the worker, never on the caller,
/// which is often the live coaching path.
public struct DiagnosticAuditEvent: Sendable {
    public let message: String
    public let date: Date

    public init(message: String, date: Date = Date()) {
        self.message = message
        self.date = date
    }

    var approximateRetainedBytes: Int {
        let (sum, overflow) = 64.addingReportingOverflow(message.utf8.count)
        return overflow ? .max : sum
    }
}
