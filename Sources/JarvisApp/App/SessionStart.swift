import JarvisCore

@MainActor
final class SessionStart {
    private struct Pending {
        let session: JarvisReadiness.Session
        let references: PendingReferenceAdmission
        let task: Task<Void, Never>
    }

    private let readiness: JarvisReadiness
    private var pending: Pending?

    init(readiness: JarvisReadiness) {
        self.readiness = readiness
    }

    var isPreparing: Bool { pending != nil }

    @discardableResult
    func prepare(
        _ session: JarvisReadiness.Session, references: PendingReferenceAdmission,
        work: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        precondition(pending == nil)
        let task = Task { [weak self] in
            defer {
                if self?.pending?.session == session { self?.pending = nil }
                references.cancel()
            }
            guard self?.isCurrent(session) == true else { return }
            await work()
        }
        pending = Pending(session: session, references: references, task: task)
        return task
    }

    func isCurrent(_ session: JarvisReadiness.Session) -> Bool {
        pending?.session == session && readiness.isCurrent(session) && !Task.isCancelled
    }

    /// The running task retains the References admission through synchronous installation.
    func finish(_ session: JarvisReadiness.Session) -> Bool {
        guard isCurrent(session) else { return false }
        pending = nil
        return true
    }

    @discardableResult
    func cancel() -> JarvisReadiness.Session? {
        guard let pending else { return nil }
        self.pending = nil
        pending.task.cancel()
        pending.references.cancel()
        return pending.session
    }
}
