import Foundation

/// `@unchecked Sendable`: the only stored property is an immutable `UserDefaults`, which is
/// thread-safe.
public final class ScreenCapturePreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The 1-based `screencapture -D` index. Ignored in active-window scope.
    public var displayIndex: Int {
        get {
            // `integer(forKey:)` returns 0 for an absent key, so check presence first.
            guard defaults.object(forKey: Defaults.Screen.displayIndexKey) != nil else {
                return Defaults.Screen.displayIndex
            }
            return max(Defaults.Screen.displayIndexMinimum,
                       defaults.integer(forKey: Defaults.Screen.displayIndexKey))
        }
        set {
            defaults.set(
                max(Defaults.Screen.displayIndexMinimum, newValue),
                forKey: Defaults.Screen.displayIndexKey)
        }
    }

    public var scope: ScreenCaptureScope {
        get {
            defaults.string(forKey: Defaults.Screen.scopeKey)
                .flatMap(ScreenCaptureScope.init(rawValue:)) ?? Defaults.Screen.scope
        }
        set { defaults.set(newValue.rawValue, forKey: Defaults.Screen.scopeKey) }
    }

    /// The user's opt-in only. The Accessibility grant is checked at capture time.
    public var browserTextEnabled: Bool {
        get {
            guard defaults.object(forKey: Defaults.Screen.browserTextEnabledKey) != nil else {
                return Defaults.Screen.browserTextEnabled
            }
            return defaults.bool(forKey: Defaults.Screen.browserTextEnabledKey)
        }
        set { defaults.set(newValue, forKey: Defaults.Screen.browserTextEnabledKey) }
    }

    /// Clears an opt-in the system can no longer honor. Returns whether the setting changed.
    @discardableResult
    public func reconcileBrowserTextAvailability(isAvailable: Bool) -> Bool {
        guard browserTextEnabled, !isAvailable else { return false }
        browserTextEnabled = false
        return true
    }

    /// Nil for a plain main-display capture. Active-window scope ignores the stored index so a
    /// stale one can't steer its fallbacks.
    public var explicitDisplay: Int? {
        scope == .entireDisplay && displayIndex > 1 ? displayIndex : nil
    }
}
