import Foundation

/// The per-session evidence handle: bounded admission, one-way close semantics, and one health
/// record covering every category the session records.
public final class FileSessionAudit: BrainTrafficAuditing, CoachingAttemptAuditing, Sendable {
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

    public convenience init(directory: URL) {
        self.init(directory: directory, worker: .shared)
    }

    init(directory: URL, worker: SessionAuditWorker) {
        self.worker = worker
        self.session = worker.openSession(at: directory)
    }

    public func record(_ event: BrainTrafficAuditEvent) {
        record(.brainTraffic(event))
    }

    public func record(_ event: CoachingAttemptAuditEvent) {
        record(.coachingAttempt(event))
    }

    /// Admit one agent-facing diagnostic against this session. Returns false when the mailbox
    /// refused it — a sealed handle or a full mailbox — so `JarvisLog` can fall back to the
    /// unattributed process log instead of dropping the line outright.
    func recordDiagnostic(_ event: DiagnosticAuditEvent) -> Bool {
        record(.diagnostic(event))
    }

    /// The one envelope admission every typed producer view converges on. The handle stamps
    /// session attribution itself, so an event can only ever claim the session it was recorded
    /// through. Internal until a later slice migrates producers onto the envelope directly; the
    /// Activity presentation stays unused until Phase 2 moves Activity onto `SessionEvent`.
    @discardableResult
    func record(
        _ detail: SessionEvent.Detail,
        presentingInActivity presentation: ActivityLog.Event? = nil
    ) -> Bool {
        worker.record(
            SessionEvent(
                sessionID: session.id,
                detail: detail,
                activityPresentation: presentation),
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
