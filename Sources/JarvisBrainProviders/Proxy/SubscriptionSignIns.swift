import Foundation
import JarvisCore

@MainActor
public final class SubscriptionSignIns {
    public private(set) var selectable: Set<BrainProvider>?
    public private(set) var readiness: LocalProxySupervisor.Readiness?
    public private(set) var retrying: BrainProvider?

    private let supervisor: LocalProxySupervisor
    private var probe: Task<Void, Never>?
    private var signIns: [BrainProvider: Task<Void, Never>] = [:]
    private var signingOut: Set<BrainProvider> = []
    private var actionFailures: [BrainProvider: String] = [:]
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
        guard provider.servedByLocalProxy, retrying == nil,
              signIns.isEmpty, signingOut.isEmpty else { return }
        actionFailures[provider] = nil
        check(refreshing: provider)
    }

    public func connection(for provider: BrainProvider) -> SubscriptionConnectionState {
        let accounts = supervisor.accountFiles(for: provider)
        let accountDescription = accounts.first.map {
            [$0.email, $0.plan].compactMap { $0 }.joined(separator: " · ")
        }.flatMap { $0.isEmpty ? nil : $0 }
        let health = readiness.map {
            $0.unavailability(for: provider).map { BrainRouteAvailability.ConnectionHealth.unavailable($0) } ?? .ready
        } ?? .checking
        let operation: SubscriptionConnectionState.Operation?
        if signIns[provider] != nil { operation = .signingIn }
        else if signingOut.contains(provider) { operation = .signingOut }
        else if retrying == provider { operation = .retrying }
        else { operation = nil }
        return SubscriptionConnectionState(
            provider: provider, savedAccountCount: accounts.count, accountDescription: accountDescription,
            health: health, operation: operation,
            retryAvailable: retrying == nil && signIns.isEmpty && signingOut.isEmpty,
            accountActionsAvailable: retrying == nil,
            actionFailure: actionFailures[provider])
    }

    public func perform(
        _ action: SubscriptionConnectionState.Action, for provider: BrainProvider,
        openURL: @escaping (URL) -> Void, willSignOut: (BrainProvider) -> Void
    ) {
        guard provider.servedByLocalProxy,
              connection(for: provider).buttons.contains(where: { $0.action == action && $0.isEnabled }) else { return }
        switch action {
        case .retry:
            retry(provider)
        case .cancelSignIn:
            signIns[provider]?.cancel()
        case .signIn:
            signIn(provider, openURL: openURL)
        case .signOut:
            actionFailures[provider] = nil
            signingOut.insert(provider)
            willSignOut(provider)
            notifyObservers()
            Task { await signOut(provider) }
        }
    }

    private func signIn(_ provider: BrainProvider, openURL: @escaping (URL) -> Void) {
        actionFailures[provider] = nil
        // The login owns the OAuth callback port even after Settings releases its views.
        signIns[provider] = Task { [weak self, supervisor] in
            var failure: String?
            if let signIn = await supervisor.makeSignIn() {
                for await event in signIn.run(provider) {
                    switch event {
                    case .openURL(let url): openURL(url)
                    case .finished: break
                    case .failed(let message): failure = message
                    }
                }
            } else {
                failure = "the sign-in service isn't running"
            }
            await supervisor.credentialsDidChange()
            guard let self else { return }
            signIns[provider] = nil
            if let failure, !Task.isCancelled {
                actionFailures[provider] = "Sign-in failed: \(ProviderMessageRedaction.redact(failure))"
            }
            invalidate()
            refresh(checkingEmptyAccounts: true)
        }
        notifyObservers()
    }

    private func signOut(_ provider: BrainProvider) async {
        do {
            try await supervisor.signOut(provider)
        } catch {
            actionFailures[provider] = "Sign-out failed: "
                + ProviderMessageRedaction.redact(error.localizedDescription)
        }
        signingOut.remove(provider)
        invalidate()
        refresh(checkingEmptyAccounts: true)
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

    public func health(among targets: Set<BrainTarget>) -> [BrainTarget: BrainRouteAvailability.ConnectionHealth] {
        Dictionary(uniqueKeysWithValues: targets.map { target in
            let provider = target.provider
            let health: BrainRouteAvailability.ConnectionHealth
            if supervisor.accountFiles(for: provider).isEmpty {
                health = .unavailable(ProviderFailure(
                    source: .brain(provider), stage: .process, category: .authentication,
                    disposition: .permanent, identity: .init(), message: "Sign in in Settings → Connections."))
            } else if let readiness {
                health = readiness.unavailability(for: target).map { .unavailable($0) } ?? .ready
            } else {
                health = .checking
            }
            return (target, health)
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
