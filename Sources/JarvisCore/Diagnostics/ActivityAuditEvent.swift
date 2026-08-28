import Foundation

/// One occurrence whose whole content is its human-facing Activity row: finalized speech, a manual
/// hint, a brain action, or a fixed lifecycle/degradation notice.
///
/// It is a typed detail like brain traffic or a coaching attempt, so an Activity occurrence travels
/// the one shared evidence transport as a single `SessionEvent` rather than being mirrored into a
/// second stack (wiki/lean-coaching-core.md, "One Event, Two Projections").
public struct ActivityAuditEvent: Sendable {
    public let presentation: ActivityEvent
    /// When the occurrence happened. Speech carries its own speech-time so the Activity window and
    /// the model share one chronology; everything else happens when it is recorded.
    public let date: Date

    public init(presentation: ActivityEvent, date: Date) {
        self.presentation = presentation
        self.date = date
    }

    /// Mailbox accounting. A screen-view row retains a base64 JPEG, which is by far the largest
    /// thing the human projection ever carries — the byte bound has to see it.
    var approximateRetainedBytes: Int {
        let rendered = presentation.rendered
        var bytes = 64
        bytes = Self.adding(bytes, rendered.message.utf8.count)
        bytes = Self.adding(bytes, rendered.imageBase64?.utf8.count ?? 0)
        return bytes
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
