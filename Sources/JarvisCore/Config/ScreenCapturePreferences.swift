import Foundation

/// Persisted screen-capture selection: what `capture_screen` shoots (`scope`) and, for
/// entire-display captures, which display — stored as the 1-based index `screencapture -D` uses
/// (1 = the main display, the one with the menu bar).
/// Backed by UserDefaults; reads clamp so an absent or nonsense value falls back to the default.
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests. Mirrors `BrainPreferences`.
///
/// `@unchecked Sendable`: the only stored property is an immutable reference to `UserDefaults`,
/// which is documented thread-safe — `ScreenCaptureCLI` reads the selection off the main actor at
/// capture time while the Settings pane writes it on the main actor.
public final class ScreenCapturePreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let displayIndex = "screen.captureDisplayIndex"
        static let scope = "screen.captureScope"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Which display entire-display captures shoot, as the 1-based index `screencapture -D`
    /// counts (1 = main display). Absent or < 1 → 1. Ignored in active-window scope.
    public var displayIndex: Int {
        get { max(1, defaults.integer(forKey: Key.displayIndex)) }
        set { defaults.set(max(1, newValue), forKey: Key.displayIndex) }
    }

    /// What to capture: the active window (default) or the entire selected display. Absent or
    /// unrecognized stored values fall back to the default, like `displayIndex` clamps.
    public var scope: ScreenCaptureScope {
        get { defaults.string(forKey: Key.scope).flatMap(ScreenCaptureScope.init(rawValue:)) ?? .activeWindow }
        set { defaults.set(newValue.rawValue, forKey: Key.scope) }
    }

    /// The display a capture must explicitly target (`screencapture -D`), or nil when a plain
    /// capture — which shoots the main display — is right: active-window scope, where fallbacks
    /// must not be steered by an index left over from an old entire-display selection, and
    /// entire-display scope on the main display itself.
    public var explicitDisplay: Int? {
        scope == .entireDisplay && displayIndex > 1 ? displayIndex : nil
    }
}
