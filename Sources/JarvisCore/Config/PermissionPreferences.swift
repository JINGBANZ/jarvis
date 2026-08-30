import Foundation

/// The two things Jarvis has to remember about macOS permissions between launches: whether the
/// first-launch checklist has been shown, and whether a Core Audio tap has ever started.
///
/// The system-audio flag exists because macOS ships no API to request or read that grant — an
/// adapter can only find out by building a tap-backed device and starting it. Caching the answer
/// keeps that probe off every launch and out of the Start path. A grant revoked afterwards makes
/// this flag stale; capture construction still fails with its own notice, which is the recovery
/// path a stale `true` degrades to.
///
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests. Mirrors `PrepMaterialPreferences`.
public final class PermissionPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the first-launch permission checklist has already been presented. Set once it has,
    /// whether or not the user granted anything — declining must not re-open it every launch.
    public var onboardingShown: Bool {
        get {
            defaults.object(forKey: Defaults.Permissions.onboardingShownKey) as? Bool
                ?? Defaults.Permissions.onboardingShown
        }
        set { defaults.set(newValue, forKey: Defaults.Permissions.onboardingShownKey) }
    }

    /// Whether a tap-backed device has started successfully at least once.
    public var systemAudioGranted: Bool {
        get {
            defaults.object(forKey: Defaults.Permissions.systemAudioGrantedKey) as? Bool
                ?? Defaults.Permissions.systemAudioGranted
        }
        set { defaults.set(newValue, forKey: Defaults.Permissions.systemAudioGrantedKey) }
    }
}
