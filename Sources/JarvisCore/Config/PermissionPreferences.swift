import Foundation

/// Never records a grant: a stored grant can't be told apart from a current one.
public final class PermissionPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `CGRequestScreenCaptureAccess` returns false whether the user allowed or refused, and
    /// preflight is fixed for the process. So on a later launch, asked and still missing means
    /// refused.
    public var screenRecordingAsked: Bool {
        get {
            defaults.object(forKey: Defaults.Permissions.screenRecordingAskedKey) as? Bool
                ?? Defaults.Permissions.screenRecordingAsked
        }
        set { defaults.set(newValue, forKey: Defaults.Permissions.screenRecordingAskedKey) }
    }
}
