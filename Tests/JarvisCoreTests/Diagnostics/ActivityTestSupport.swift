import Foundation
@testable import JarvisCore

extension ActivityLog {
    /// Compose the shape the app composes: one session directory, one evidence handle, and this
    /// projection behind it. Producers record into the handle; the shared worker writes the row and
    /// its attachment and then hands the row to the projection.
    ///
    /// The handle owns its own worker so parallel suites cannot see each other's rows, and
    /// `close()` is the drain barrier that replaced the projection's deleted `flush()`.
    static func recordingSession(in directory: URL) -> (ActivityLog, FileSessionAudit) {
        let log = ActivityLog()
        log.enable(directory: directory)
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()),
            activity: log)
        return (log, evidence)
    }
}
