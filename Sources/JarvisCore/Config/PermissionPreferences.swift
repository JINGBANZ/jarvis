import Foundation

/// The one thing Jarvis remembers about macOS permissions between launches: that it has asked for
/// Screen Recording.
///
/// Nothing here records a *grant*. A stored grant is indistinguishable from a current one, and the
/// caller that has to decide whether a session can run cannot tell which it is holding — so grants
/// are proved live, by reading them or by probing for them, and never remembered. That this app
/// asked, by contrast, is a fact about Jarvis's own behaviour and cannot become untrue.
///
/// It is needed because macOS hides a Screen Recording answer from the process that asks:
/// `CGRequestScreenCaptureAccess` returns false whether the user allowed or refused. A later launch
/// that asked before and still lacks the grant is therefore looking at a refusal, not at a grant
/// waiting for a relaunch. Without that distinction the gate loops the user through Quit & Reopen
/// forever.
///
/// Nothing records whether the gate has run: it appears whenever the grants are incomplete, so its
/// own condition is the only state it needs.
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
}
