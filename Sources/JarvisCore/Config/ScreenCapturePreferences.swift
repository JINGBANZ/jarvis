import Foundation

/// Persisted screen-capture display selection: which display `capture_screen` screenshots, stored as
/// the 1-based index `screencapture -D` uses (1 = the main display, the one with the menu bar).
/// Backed by UserDefaults; reads clamp so an absent or nonsense value falls back to the main display.
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

    /// The 1-based display index as `screencapture -D` counts (1 = main display). Absent or < 1 → 1.
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
}
