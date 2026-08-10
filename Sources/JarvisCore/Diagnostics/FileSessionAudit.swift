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

    private final class SynchronousCloseResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SessionAuditCloseResult?

        func store(_ result: SessionAuditCloseResult) {
            lock.withLock { stored = result }
        }

        var value: SessionAuditCloseResult? {
            lock.withLock { stored }
        }
    }

    private let worker: SessionAuditWorker
    private let session: SessionAuditWorker.Session

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
        let accepted = worker.close(session, deadline: closeDeadline) { result in
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

    public func closeSynchronously(
        deadline: Duration = FileSessionAudit.defaultCloseDeadline
    ) -> SessionAuditCloseResult {
        let deadline = max(.zero, deadline)
        session.seal()
        let completion = DispatchSemaphore(value: 0)
        let result = SynchronousCloseResult()
        let closeDeadline = ContinuousClock.now.advanced(by: deadline)
        let accepted = worker.close(session, deadline: closeDeadline) { value in
            result.store(value)
            completion.signal()
        }
        guard accepted else {
            session.health.markCloseTimeout()
            return .partial
        }

        let components = deadline.components
        let seconds = max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        guard completion.wait(timeout: .now() + seconds) == .success,
              let result = result.value
        else {
            session.health.markCloseTimeout()
            return .partial
        }
        return result
    }

    var healthSnapshot: SessionAuditWorker.HealthSnapshot {
        session.health.snapshot
    }
}
