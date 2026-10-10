import Foundation

public struct RobotReadiness: Sendable, Equatable {
    public enum ConnectionHealth: Sendable, Equatable {
        case checking
        case ready
        case unavailable(ProviderFailure)
    }

    public var subscriptions: [BrainProvider: ConnectionHealth]
    public var availableCredentials: Set<Credential>
    public var grantedPermissions: Set<JarvisReadiness.Permission>

    public init(
        subscriptions: [BrainProvider: ConnectionHealth],
        availableCredentials: Set<Credential>,
        grantedPermissions: Set<JarvisReadiness.Permission>
    ) {
        self.subscriptions = subscriptions
        self.availableCredentials = availableCredentials
        self.grantedPermissions = grantedPermissions
    }
}
