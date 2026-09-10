import Foundation

/// Read by Settings and snapshotted into SessionPlan at explicit revision boundaries.
public final class ExplanationPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get {
            defaults.object(forKey: Defaults.Explanations.enabledKey) as? Bool
                ?? Defaults.Explanations.enabled
        }
        set { defaults.set(newValue, forKey: Defaults.Explanations.enabledKey) }
    }
}
