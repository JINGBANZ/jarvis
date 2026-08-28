import Foundation

/// Where `jlog` sends agent-facing diagnostics.
///
/// `jlog` performs no persistence and no Console work of its own. It builds one typed
/// `DiagnosticAuditEvent` and admits it — nonthrowing, nonblocking, constant time — to the shared
/// bounded session-evidence transport. Timestamp rendering, `NSLog`, file opening, seeking, and
/// writing all run on that one worker, off whatever thread the coach happened to be using
/// (wiki/lean-coaching-core.md, "Phase 1 Implementation Contract").
///
/// Attribution is by immutable session handle, never by proximity in time. While a session is
/// attached its diagnostics land in that session's `jarvis-debug.log`; with no attachment, or once
/// the attached handle is sealed, they reach the asynchronous process log (Console) only. A
/// diagnostic is never guessed into whichever session happens to be newest — a mis-attributed
/// diagnostic is worse evidence than a missing one.
public enum JarvisLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var session: FileSessionAudit?   // guarded by `lock`

    /// Point `jlog` at the live session's evidence handle. Called once per Start, after the handle
    /// exists, so every diagnostic from that point carries that session's identity.
    public static func attach(to evidence: FileSessionAudit) {
        lock.withLock { session = evidence }
    }

    /// Stop attributing diagnostics to any session. Not required by Stop — a sealed handle already
    /// refuses late events — but it lets a test restore process-global state it changed.
    public static func detach() {
        lock.withLock { session = nil }
    }

    fileprivate static func emit(_ message: String) {
        let event = DiagnosticAuditEvent(message: message)
        if let session = lock.withLock({ session }), session.recordDiagnostic(event) { return }
        SessionAuditWorker.shared.recordProcessDiagnostic(event)
    }
}

/// Agent-facing diagnostic logger. It deliberately never writes to `ActivityLog`, whose entries are
/// a separate, human-facing coaching record.
public func jlog(_ message: String) {
    JarvisLog.emit(message)
}
