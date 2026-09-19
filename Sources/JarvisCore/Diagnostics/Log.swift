import Foundation

/// Attribution is by session handle, never by time. With no live handle, diagnostics go to Console
/// only: a misattributed line is worse evidence than a missing one.
public enum JarvisLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var session: FileSessionAudit?   // guarded by `lock`

    nonisolated(unsafe) private static var suppressed = false // guarded by `lock`

    /// The explicit microphone benchmark retains measurements only, including during late teardown.
    public static func suppressForProcess() {
        lock.withLock { suppressed = true }
    }

    public static func attach(to evidence: FileSessionAudit) {
        lock.withLock { session = evidence }
    }

    /// Stop doesn't need this, since a sealed handle refuses late events. Tests use it to reset.
    public static func detach() {
        lock.withLock { session = nil }
    }

    fileprivate static func emit(_ message: String) {
        guard !lock.withLock({ suppressed }) else { return }
        let event = DiagnosticAuditEvent(message: message)
        if let session = lock.withLock({ session }), session.recordDiagnostic(event) { return }
        SessionAuditWorker.shared.recordProcessDiagnostic(event)
    }
}

/// Never writes to `ActivityLog`, which is the human-facing record.
public func jlog(_ message: String) {
    JarvisLog.emit(message)
}
