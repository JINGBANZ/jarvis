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
    private var provenSignedIn: Set<BrainProvider>?
    private let supervisor: LocalProxySupervisor
    private var probe: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]

    init(supervisor: LocalProxySupervisor) {
        self.supervisor = supervisor
    }

    func refresh() {
        guard probe == nil else { return }
        let hasSavedSignIn = BrainProvider.allCases.filter(\.servedByLocalProxy).contains {
            !supervisor.accountFiles(for: $0).isEmpty
        }
        guard hasSavedSignIn else {
            update(selectable: [], provenSignedIn: provenSignedIn)
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
        probe?.cancel()
        probe = nil
        switch readiness {
        case .ready(_, let signedIn):
            update(selectable: signedIn, provenSignedIn: signedIn)
        case .unavailable:
            update(selectable: [], provenSignedIn: provenSignedIn)
        }
    }

    /// Of `providers`, the ones proven signed out: no saved sign-in, or the last real answer lacked them.
    func signedOut(among providers: Set<BrainProvider>) -> Set<BrainProvider> {
        providers.filter { provider in
            supervisor.accountFiles(for: provider).isEmpty
                || (provenSignedIn.map { !$0.contains(provider) } ?? false)
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
        provenSignedIn newProven: Set<BrainProvider>?
    ) {
        guard newSelectable != selectable || newProven != provenSignedIn else { return }
        selectable = newSelectable
        provenSignedIn = newProven
        for handler in observers.values { handler() }
    }
}
