import Foundation

public struct RobotReadiness: Sendable, Equatable {
    public var subscriptions: [BrainProvider: BrainRouteAvailability.ConnectionHealth]
    public var availableCredentials: Set<Credential>
    public var grantedPermissions: Set<JarvisReadiness.Permission>

    public init(
        subscriptions: [BrainProvider: BrainRouteAvailability.ConnectionHealth],
        availableCredentials: Set<Credential>,
        grantedPermissions: Set<JarvisReadiness.Permission>
    ) {
        self.subscriptions = subscriptions
        self.availableCredentials = availableCredentials
        self.grantedPermissions = grantedPermissions
    }
}
