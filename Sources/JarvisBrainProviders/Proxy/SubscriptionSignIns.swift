import Foundation
import JarvisCore

@MainActor
public final class SubscriptionSignIns {
    public private(set) var selectable: Set<BrainProvider>?
    public private(set) var readiness: LocalProxySupervisor.Readiness?
    public private(set) var retrying: BrainProvider?

    private let supervisor: LocalProxySupervisor
    private var probe: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]

    public init(supervisor: LocalProxySupervisor) {
        self.supervisor = supervisor
    }

    public func refresh(replacingPending: Bool = false, checkingEmptyAccounts: Bool = false) {
        guard retrying == nil, probe == nil || replacingPending else { return }
        let hasSavedSignIn = BrainProvider.allCases.filter(\.servedByLocalProxy).contains {
            !supervisor.accountFiles(for: $0).isEmpty
        }
        guard hasSavedSignIn || checkingEmptyAccounts else {
            probe?.cancel()
            probe = nil
            readiness = nil
            selectable = []
            notifyObservers()
            return
        }
        check(refreshing: nil)
    }

    public func retry(_ provider: BrainProvider) {
        guard provider.servedByLocalProxy, retrying == nil else { return }
        check(refreshing: provider)
    }

    private func check(refreshing provider: BrainProvider?) {
        probe?.cancel()
        retrying = provider
        probe = Task { [weak self, supervisor] in
            let providers = Set([provider].compactMap { $0 })
            let readiness = await supervisor.readiness(refreshing: providers)
            guard let self, !Task.isCancelled else { return }
            probe = nil
            retrying = nil
            if readiness != .superseded {
                self.readiness = readiness
                selectable = readiness.signedIn
            }
            notifyObservers()
        }
        notifyObservers()
    }

    public func record(_ readiness: LocalProxySupervisor.Readiness) {
        // A snapshot from Start must not interrupt the user's explicit retry.
        guard readiness != .superseded, retrying == nil else { return }
        probe?.cancel()
        probe = nil
        self.readiness = readiness
        selectable = readiness.signedIn
        notifyObservers()
    }

    public func invalidate() {
        probe?.cancel()
        probe = nil
        retrying = nil
        readiness = nil
        selectable = nil
        notifyObservers()
    }

    public func health(among providers: Set<BrainProvider>) -> [BrainProvider: BrainRouteAvailability.ConnectionHealth] {
        Dictionary(uniqueKeysWithValues: providers.map { provider in
            let health: BrainRouteAvailability.ConnectionHealth
            if supervisor.accountFiles(for: provider).isEmpty {
                health = .unavailable(ProviderFailure(
                    source: .brain(provider), stage: .process, category: .authentication,
                    disposition: .permanent, identity: .init(), message: "Sign in in Settings → Connections."))
            } else if let readiness {
                health = readiness.unavailability(for: provider).map { .unavailable($0) } ?? .ready
            } else {
                health = .checking
            }
            return (provider, health)
        })
    }

    @discardableResult
    public func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notifyObservers() {
        for handler in observers.values { handler() }
    }
}
