import Foundation

/// File-backed session audit with bounded, nonblocking admission and deadline-bound lifecycle close.
///
/// `Sendable` is compiler-checked: the handle stores only immutable references. The worker owns all
/// file mutation, `Session` owns only atomic state, and `PersistenceSettlement` locks its waiters.
public final class FileSessionAudit: BrainTrafficAuditing, CoachingAttemptAuditing,
    SessionAuditLifecycle, Sendable {
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
    /// a separate settlement gate so UI consumers can refuse mutable evidence until the worker's
    /// close envelope has actually finished, including a corrective partial-marker write.
    /// `@unchecked Sendable`: `lock` protects the mutation count and continuation array; the state
    /// callback is immutable and always invoked after releasing that lock.
    private final class PersistenceSettlement: @unchecked Sendable {
        private let lock = NSLock()
        private let onStateChange: (@Sendable (Bool) -> Void)?
        /// The initial mutation is the close envelope. A rejected post-seal record temporarily adds
        /// another mutation until the worker has made the canonical marker safely partial.
        private var pendingMutations = 1
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(onStateChange: (@Sendable (Bool) -> Void)?) {
            self.onStateChange = onStateChange
        }

        var isSettled: Bool {
            lock.withLock { pendingMutations == 0 }
        }

        func beginMutation() {
            let becameUnsettled = lock.withLock {
                let wasSettled = pendingMutations == 0
                pendingMutations += 1
                return wasSettled
            }
            if becameUnsettled { onStateChange?(false) }
        }

        func finishMutation() {
            let result = lock.withLock {
                guard pendingMutations > 0 else {
                    return (false, [CheckedContinuation<Void, Never>]())
                }
                pendingMutations -= 1
                guard pendingMutations == 0 else {
                    return (false, [CheckedContinuation<Void, Never>]())
                }
                let continuations = waiters
                waiters.removeAll()
                return (true, continuations)
            }
            result.1.forEach { $0.resume() }
            if result.0 { onStateChange?(true) }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if pendingMutations == 0 { return true }
                    waiters.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }
    }

    private let worker: SessionAuditWorker
    private let session: SessionAuditWorker.Session
    private let persistenceSettlement: PersistenceSettlement

    public convenience init(
        directory: URL,
        onPersistenceStateChange: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.init(
            directory: directory,
            worker: .shared,
            onPersistenceStateChange: onPersistenceStateChange)
    }

    init(
        directory: URL,
        worker: SessionAuditWorker,
        onPersistenceStateChange: (@Sendable (Bool) -> Void)? = nil
    ) {
        let settlement = PersistenceSettlement(onStateChange: onPersistenceStateChange)
        self.worker = worker
        self.persistenceSettlement = settlement
        self.session = worker.openSession(
            at: directory,
            persistenceMutationBegan: { settlement.beginMutation() },
            persistenceMutationFinished: { settlement.finishMutation() })
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
        let admission = worker.close(
            session,
            deadline: closeDeadline
        ) { [persistenceSettlement] result in
            persistenceSettlement.finishMutation()
            streamPair.continuation.yield(result)
            streamPair.continuation.finish()
        }
        switch admission {
        case .deferred:
            return .partial
        case .alreadyClosing:
            return persistenceSettlement.isSettled && session.health.snapshot.isComplete
                ? .complete
                : .partial
        case .enqueued:
            break
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

    /// Whether the session directory is currently safe for the evaluator to read. A late observer
    /// call can make a previously settled session unavailable again until its marker is invalidated.
    public var isPersistenceSettled: Bool {
        persistenceSettlement.isSettled
    }

    var healthSnapshot: SessionAuditWorker.HealthSnapshot {
        session.health.snapshot
    }
}
