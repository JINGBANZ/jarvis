import Foundation

/// One agent-facing diagnostic occurrence retained by the shared session-evidence worker.
///
/// The event keeps the already-formatted message and the moment it happened, and nothing else.
/// Timestamp rendering, Console emission, file opening, seeking, and writing all run after bounded
/// mailbox admission — never on the caller, which is frequently the live coaching path
/// (wiki/lean-coaching-core.md, "Phase 1 Implementation Contract").
public struct DiagnosticAuditEvent: Sendable {
    public let message: String
    public let date: Date

    public init(message: String, date: Date = Date()) {
        self.message = message
        self.date = date
    }

    /// Mailbox accounting: the retained string plus the fixed struct overhead. A diagnostic is small
    /// next to a brain-traffic body, but it shares the one count/byte bound with every other
    /// category — no evidence kind gets reserved capacity.
    var approximateRetainedBytes: Int {
        let (sum, overflow) = 64.addingReportingOverflow(message.utf8.count)
        return overflow ? .max : sum
    }
}
