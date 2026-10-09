import Foundation
import JarvisBrainProviders
import JarvisCore

/// Asks the helper only when a sign-in is saved, so opening Settings never starts it for nothing. A
/// fresh answer cancels any probe in flight, so an older answer can't land on top of it.
@MainActor
final class SubscriptionSignIns {
    /// `nil` before any answer. A helper that isn't running serves nothing, so it empties this.
    private(set) var selectable: Set<BrainProvider>?

    /// A helper that couldn't answer proves nothing, so it leaves this alone.
    private var provenSignedOut: Set<BrainProvider> = []
    private(set) var readiness: LocalProxySupervisor.Readiness?
    private let supervisor: LocalProxySupervisor
    private var probe: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]

    init(supervisor: LocalProxySupervisor) {
        self.supervisor = supervisor
    }

    func refresh(replacingPending: Bool = false) {
        if replacingPending {
            probe?.cancel()
            probe = nil
        }
        guard probe == nil else { return }
        let hasSavedSignIn = BrainProvider.allCases.filter(\.servedByLocalProxy).contains {
            !supervisor.accountFiles(for: $0).isEmpty
        }
        guard hasSavedSignIn else {
            update(selectable: [], provenSignedOut: provenSignedOut)
            return
        }
        probe = Task { [weak self, supervisor] in
            let readiness = await supervisor.readiness()
            guard let self, !Task.isCancelled else { return }
            probe = nil
            record(readiness)
        }
    }

    func record(_ readiness: LocalProxySupervisor.Readiness) {
        guard readiness != .superseded else { return }
        probe?.cancel()
        probe = nil
        self.readiness = readiness
        switch readiness {
        case .superseded: break
        case .ready(_, let signedIn, _):
            let signedOut = Set(BrainProvider.allCases.filter { provider in
                guard provider.servedByLocalProxy else { return false }
                let failure = readiness.unavailability(for: provider)
                return failure?.category == .authentication && failure?.disposition == .permanent
            })
            update(selectable: signedIn, provenSignedOut: signedOut)
        case .unavailable:
            update(selectable: [], provenSignedOut: provenSignedOut)
        }
    }

    /// Of `providers`, the ones proven signed out: no saved sign-in or rejected credentials.
    func signedOut(among providers: Set<BrainProvider>) -> Set<BrainProvider> {
        providers.filter { provider in
            supervisor.accountFiles(for: provider).isEmpty
                || provenSignedOut.contains(provider)
        }
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func update(
        selectable newSelectable: Set<BrainProvider>,
        provenSignedOut newProven: Set<BrainProvider>
    ) {
        selectable = newSelectable
        provenSignedOut = newProven
        for handler in observers.values { handler() }
    }
}
