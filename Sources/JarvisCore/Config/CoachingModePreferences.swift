import Foundation

/// `@unchecked Sendable`: `UserDefaults` is thread-safe and this type holds no other state.
public final class CoachingModePreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mode: CoachingMode {
        get {
            defaults.string(forKey: Defaults.Coaching.modeKey).flatMap(CoachingMode.init(rawValue:))
                ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Defaults.Coaching.modeKey) }
    }
}
