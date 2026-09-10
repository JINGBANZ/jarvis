import Foundation

/// Read by Settings and snapshotted into SessionPlan at explicit revision boundaries.
public final class CodePreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get {
            defaults.object(forKey: Defaults.Code.enabledKey) as? Bool
                ?? Defaults.Code.enabled
        }
        set { defaults.set(newValue, forKey: Defaults.Code.enabledKey) }
    }
}
