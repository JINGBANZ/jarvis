import Foundation

public struct BrainRouteAvailability: Sendable, Equatable {
    public enum ConnectionHealth: Sendable, Equatable {
        case checking
        case ready
        case unavailable(ProviderFailure)
    }

    public enum State: Sendable, Equatable {
        case checking
        case ready(BrainTarget, primaryFailure: ProviderFailure?)
        case unavailable(ProviderFailure)
    }

    private let route: BrainRoute
    private let availableCredentials: Set<Credential>
    private let subscriptions: [BrainTarget: ConnectionHealth]

    public init(
        route: BrainRoute,
        availableCredentials: Set<Credential>,
        subscriptions: [BrainTarget: ConnectionHealth]
    ) {
        self.route = route
        self.availableCredentials = availableCredentials
        self.subscriptions = subscriptions
    }

    public func health(for target: BrainTarget) -> ConnectionHealth {
        if let failure = target.credentialFailure(available: availableCredentials) {
            return .unavailable(failure)
        }
        guard target.provider.servedByLocalProxy else { return .ready }
        return subscriptions[target] ?? .checking
    }

    public var state: State {
        switch health(for: route.primary) {
        case .ready: return .ready(route.primary, primaryFailure: nil)
        case .checking: return .checking
        case .unavailable(let failure):
            for fallback in route.fallbackTargets {
                switch health(for: fallback) {
                case .ready: return .ready(fallback, primaryFailure: failure)
                case .checking: return .checking
                case .unavailable: continue
                }
            }
            return .unavailable(failure)
        }
    }

    public var blockingFailure: ProviderFailure? {
        switch state {
        case .ready: nil
        case .unavailable(let failure): failure
        case .checking: failure(for: route.primary)
        }
    }

    public func failure(for target: BrainTarget) -> ProviderFailure? {
        switch health(for: target) {
        case .ready: nil
        case .unavailable(let failure): failure
        case .checking:
            ProviderFailure(
                source: .brain(target.provider), stage: .process, category: .unavailable,
                disposition: .temporary, identity: .init(),
                message: "Credential health is still being checked.")
        }
    }
}
