import Foundation

public final class FileSessionAudit:
    BrainTrafficAuditing, CoachingAttemptAuditing, ActivityEventRecording, Sendable {
    public static let brainTrafficFilename = "brain-traffic.jsonl"
    public static let coachingAttemptsFilename = "coaching-attempts.jsonl"
    public static let healthFilename = "audit-health.json"
    public static let diagnosticFilename = "jarvis-debug.log"
    public static let formatVersion = 1

    /// `@unchecked Sendable`: `lock` guards the result and every continuation.
    private final class CloseSettlement: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var result: SessionAuditCloseResult?
        private var waiters: [CheckedContinuation<SessionAuditCloseResult, Never>] = []

        func begin() -> Bool {
            lock.withLock {
                guard !started else { return false }
                started = true
                return true
            }
        }

        func finish(_ result: SessionAuditCloseResult) {
            let continuations = lock.withLock {
                guard self.result == nil else {
                    return [CheckedContinuation<SessionAuditCloseResult, Never>]()
                }
                self.result = result
                let continuations = waiters
                waiters.removeAll()
                return continuations
            }
            continuations.forEach { $0.resume(returning: result) }
        }

        func wait() async -> SessionAuditCloseResult {
            await withCheckedContinuation { continuation in
                let settled = lock.withLock { () -> SessionAuditCloseResult? in
                    if let result { return result }
                    waiters.append(continuation)
                    return nil
                }
                if let settled { continuation.resume(returning: settled) }
            }
        }
    }

    private let worker: SessionAuditWorker
    private let session: SessionAuditWorker.Session
    private let closeSettlement = CloseSettlement()

    /// With a nil `activity`, the session records everything except the human-facing window.
    public convenience init(directory: URL, activity: ActivityLog? = nil) {
        self.init(directory: directory, worker: .shared, activity: activity)
    }

    init(directory: URL, worker: SessionAuditWorker, activity: ActivityLog? = nil) {
        self.worker = worker
        self.session = worker.openSession(at: directory, activity: activity)
    }

    public var sessionID: UUID { session.id }

    public func record(_ event: BrainTrafficAuditEvent) {
        record(.brainTraffic(event))
    }

    public func record(_ event: CoachingAttemptAuditEvent) {
        record(.coachingAttempt(event))
    }

    public func record(_ event: ActivityEvent, at date: Date) {
        record(.activity(ActivityAuditEvent(presentation: event, date: date)))
    }

    /// False when refused (sealed or full), so `JarvisLog` can fall back to the process log.
    func recordDiagnostic(_ event: DiagnosticAuditEvent) -> Bool {
        record(.diagnostic(event))
    }

    /// The handle stamps attribution, so an event can only claim the session it came through.
    @discardableResult
    func record(_ detail: SessionEvent.Detail) -> Bool {
        worker.record(
            SessionEvent(sessionID: session.id, detail: detail),
            for: session)
    }

    /// Call from a background task so it never blocks a replacement session's Start.
    public func close() async -> SessionAuditCloseResult {
        session.seal()
        if closeSettlement.begin() {
            worker.close(session, forcePartial: false) { [closeSettlement] result in
                closeSettlement.finish(result)
            }
        }
        return await closeSettlement.wait()
    }

    /// Doesn't wait to persist. A fast exit can leave `in_progress`, which also reads as partial.
    public func abandon() {
        session.seal()
        guard closeSettlement.begin() else { return }
        worker.close(session, forcePartial: true) { [closeSettlement] result in
            closeSettlement.finish(result)
        }
    }
}
