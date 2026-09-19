import Foundation

public final class OnboardingPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isCompleted: Bool {
        get {
            defaults.object(forKey: Defaults.Onboarding.completedKey) as? Bool
                ?? Defaults.Onboarding.completed
        }
        set { defaults.set(newValue, forKey: Defaults.Onboarding.completedKey) }
    }
}
