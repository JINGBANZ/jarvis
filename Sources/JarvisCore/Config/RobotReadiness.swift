import Foundation

/// What the Settings hub's status rules read besides saved settings.
public struct RobotReadiness: Sendable, Equatable {
    /// Subscriptions proven signed out: no saved sign-in, or the helper answered without them. A
    /// helper that couldn't answer proves nothing, so it adds nothing here.
    public var signedOutSubscriptions: Set<BrainProvider>
    public var availableCredentials: Set<Credential>
    public var grantedPermissions: Set<JarvisReadiness.Permission>

    public init(
        signedOutSubscriptions: Set<BrainProvider>,
        availableCredentials: Set<Credential>,
        grantedPermissions: Set<JarvisReadiness.Permission>
    ) {
        self.signedOutSubscriptions = signedOutSubscriptions
        self.availableCredentials = availableCredentials
        self.grantedPermissions = grantedPermissions
    }
}
