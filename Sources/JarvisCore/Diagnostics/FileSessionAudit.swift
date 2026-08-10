import Foundation

/// File-backed session audit with bounded, nonblocking admission and deadline-bound lifecycle close.
public final class FileSessionAudit: BrainTrafficAuditing, CoachingAttemptAuditing,
    SessionAuditLifecycle, @unchecked Sendable {
    public static let brainTrafficFilename = "brain-traffic.jsonl"
    public static let coachingAttemptsFilename = "coaching-attempts.jsonl"
    public static let healthFilename = "audit-health.json"
    public static let formatVersion = 1
    public static let defaultCloseDeadline: Duration = .seconds(1)

    private enum CloseWait: Sendable {
        case completed(SessionAuditCloseResult)
        case timedOut
    }

    /// A close deadline bounds the caller's wait, not the serial worker's filesystem operation. Keep
    /// a separate one-shot settlement so UI consumers can refuse mutable evidence until the worker's
    /// close envelope has actually finished, including a corrective partial-marker write.
    private final class PersistenceSettlement: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markSettled() {
            let continuations = lock.withLock {
                guard !settled else { return [CheckedContinuation<Void, Never>]() }
                settled = true
                let continuations = waiters
                waiters.removeAll()
                return continuations
            }
            continuations.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if settled { return true }
                    waiters.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }
    }

    private let worker: SessionAuditWorker
    private let session: SessionAuditWorker.Session
    private let persistenceSettlement = PersistenceSettlement()

    public convenience init(directory: URL) {
        self.init(directory: directory, worker: .shared)
    }

    init(directory: URL, worker: SessionAuditWorker) {
        self.worker = worker
        self.session = worker.openSession(at: directory)
    }

    public func record(_ event: BrainTrafficAuditEvent) {
        worker.record(event, for: session)
    }

    public func record(_ event: CoachingAttemptAuditEvent) {
        worker.record(event, for: session)
    }

    public func close(
        deadline: Duration = FileSessionAudit.defaultCloseDeadline
    ) async -> SessionAuditCloseResult {
        let deadline = max(.zero, deadline)
        session.seal()
        let streamPair = AsyncStream<SessionAuditCloseResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let closeDeadline = ContinuousClock.now.advanced(by: deadline)
        let accepted = worker.close(
            session,
            deadline: closeDeadline
        ) { [persistenceSettlement] result in
            persistenceSettlement.markSettled()
            streamPair.continuation.yield(result)
            streamPair.continuation.finish()
        }
        guard accepted else {
            session.health.markCloseTimeout()
            return .partial
        }

        return await withTaskGroup(of: CloseWait.self) { group in
            group.addTask {
                var iterator = streamPair.stream.makeAsyncIterator()
                guard let result = await iterator.next() else { return .timedOut }
                return .completed(result)
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            switch first {
            case .completed(let result):
                return result
            case .timedOut:
                session.health.markCloseTimeout()
                return .partial
            }
        }
    }

    /// Wait until this sealed session's worker envelope has stopped touching its files. This is
    /// intentionally separate from the bounded close result: a deadline miss returns partial promptly,
    /// while Activity keeps Evaluate disabled until the corrective marker is durable.
    public func waitForPersistenceToStop() async {
        await persistenceSettlement.wait()
    }

    var healthSnapshot: SessionAuditWorker.HealthSnapshot {
        session.health.snapshot
    }
}
