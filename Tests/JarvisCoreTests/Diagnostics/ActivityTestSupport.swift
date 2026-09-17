import Foundation
@testable import JarvisCore

extension ActivityLog {
    /// Each call owns a worker so parallel suites stay isolated. Await `close()` before reading
    /// rows.
    static func recordingSession(in directory: URL) -> (ActivityLog, FileSessionAudit) {
        let log = ActivityLog()
        let evidence = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()),
            activity: log)
        log.enable(directory: directory, session: evidence.sessionID)
        return (log, evidence)
    }
}
