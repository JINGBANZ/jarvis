import Foundation

public struct ActivityAuditEvent: Sendable {
    public let presentation: ActivityEvent
    /// Speech carries its own speech time, so Activity and the model share one chronology.
    public let date: Date

    public init(presentation: ActivityEvent, date: Date) {
        self.presentation = presentation
        self.date = date
    }

    /// Must count a screen view's base64 JPEG, by far the largest thing Activity carries.
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
