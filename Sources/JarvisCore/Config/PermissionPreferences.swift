import Foundation

/// The one thing Jarvis has to remember about macOS permissions between launches: whether a Core
/// Audio tap has ever started.
///
/// It exists because macOS ships no API to request or read the System Audio Recording grant — an
/// adapter can only find out by building a tap-backed device, starting it, and listening. This is
/// the *last known* answer, not a standing truth: the gate re-proves a remembered grant at launch,
/// because a refusal cannot be left to surface downstream. A denied tap still delivers frames, and
/// `CaptureReadinessMonitor` reads frame arrival as healthy without inspecting amplitude, so a stale
/// `true` would let Jarvis report full readiness while hearing nothing from the other side.
///
/// A remembered refusal is what stops the launch probe from raising a prompt with no window on
/// screen to explain it; the gate's own walk asks for that one.
///
/// Nothing records whether the permission gate has run: it is shown whenever the grants are
/// incomplete, so its own condition is the only state it needs.
///
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests. Mirrors `PrepMaterialPreferences`.
public final class PermissionPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether Jarvis has ever asked macOS for Screen Recording.
    ///
    /// The grant is invisible to the process that asks for it: `CGRequestScreenCaptureAccess`
    /// returns false whether the user allowed or refused, and preflight keeps returning the value
    /// this process started with. A *later* launch, though, sees the truth. So "asked before, still
    /// missing" is the only proof of refusal there is, and without it a refusal is indistinguishable
    /// from a grant awaiting relaunch.
    public var screenRecordingAsked: Bool {
        get {
            defaults.object(forKey: Defaults.Permissions.screenRecordingAskedKey) as? Bool
                ?? Defaults.Permissions.screenRecordingAsked
        }
        set { defaults.set(newValue, forKey: Defaults.Permissions.screenRecordingAskedKey) }
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
