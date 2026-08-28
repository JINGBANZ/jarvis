import Foundation

/// The per-session evidence handle: bounded admission, one-way close semantics, and one health
/// record covering every category the session records.
public final class FileSessionAudit:
    BrainTrafficAuditing, CoachingAttemptAuditing, ActivityEventRecording, Sendable {
    public static let brainTrafficFilename = "brain-traffic.jsonl"
    public static let coachingAttemptsFilename = "coaching-attempts.jsonl"
    public static let healthFilename = "audit-health.json"
    /// The agent-facing debug log. Its name and content are the pre-migration contract; only the
    /// thread that writes it changed.
    public static let diagnosticFilename = "jarvis-debug.log"
    public static let formatVersion = 1

    /// `@unchecked Sendable`: the lock protects the result and every continuation. The state moves
    /// only from not-started to closing to one terminal result.
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

    /// `activity` is the terminal human-facing projection this session's Activity occurrences are
    /// rendered into, on the worker rather than on the producer's thread. Absent means the session
    /// records everything except a human-facing window.
    public convenience init(directory: URL, activity: ActivityLog? = nil) {
        self.init(directory: directory, worker: .shared, activity: activity)
    }

    init(directory: URL, worker: SessionAuditWorker, activity: ActivityLog? = nil) {
        self.worker = worker
        self.session = worker.openSession(at: directory, activity: activity)
    }

    /// This handle's session identity. The Activity projection is scoped by it, so a stopped
    /// session's late rows and its close cannot reach a replacement session's window.
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

    /// Admit one agent-facing diagnostic against this session. Returns false when the mailbox
    /// refused it — a sealed handle or a full mailbox — so `JarvisLog` can fall back to the
    /// unattributed process log instead of dropping the line outright.
    func recordDiagnostic(_ event: DiagnosticAuditEvent) -> Bool {
        record(.diagnostic(event))
    }

    /// The one envelope admission every typed producer view converges on. The handle stamps
    /// session attribution itself, so an event can only ever claim the session it was recorded
    /// through.
    @discardableResult
    func record(_ detail: SessionEvent.Detail) -> Bool {
        worker.record(
            SessionEvent(sessionID: session.id, detail: detail),
            for: session)
    }

    /// Seal the audit and wait for its accepted records plus one immutable terminal marker. Callers
    /// run this from a background lifecycle task; it never blocks a replacement session's Start.
    public func close() async -> SessionAuditCloseResult {
        session.seal()
        if closeSettlement.begin() {
            worker.close(session, forcePartial: false) { [closeSettlement] result in
                closeSettlement.finish(result)
            }
        }
        return await closeSettlement.wait()
    }

    /// Seal on an unexpected teardown and request a partial marker without waiting for persistence.
    /// A fast process exit can leave `in_progress`, which is also evaluator-visible incomplete state.
    public func abandon() {
        session.seal()
        guard closeSettlement.begin() else { return }
        worker.close(session, forcePartial: true) { [closeSettlement] result in
            closeSettlement.finish(result)
        }
    }
}
