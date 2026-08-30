import Foundation

/// Persisted binding for the manual-hint global hotkey. Backed by UserDefaults; keys and the shipped
/// ⌥⌘J default come from `Defaults.Hotkey`. Foundation-only so it stays unit-testable in JarvisCore;
/// inject a `UserDefaults(suiteName:)` in tests. Mirrors `ScreenCapturePreferences`.
///
/// `@unchecked Sendable`: the only stored property is an immutable reference to `UserDefaults`, which
/// is documented thread-safe — both `HotkeyController` and the Settings section that edits this read
/// and write on the main actor only.
public final class HotkeyPreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Absent, or a stored combination whose modifiers don't satisfy `satisfiesHotkeyRequirement`
    /// (a hand-edited or corrupted plist — the shortcut recorder never writes one), falls back to the
    /// shipped default rather than registering an unsafe combination app-wide.
    public var combination: HotkeyCombination {
        get {
            guard defaults.object(forKey: Defaults.Hotkey.keyCodeKey) != nil,
                  defaults.object(forKey: Defaults.Hotkey.modifiersKey) != nil else {
                return Defaults.Hotkey.combination
            }
            let keyCode = UInt32(
                truncatingIfNeeded: defaults.integer(forKey: Defaults.Hotkey.keyCodeKey))
            let modifiers = HotkeyModifiers(rawValue: UInt32(
                truncatingIfNeeded: defaults.integer(forKey: Defaults.Hotkey.modifiersKey)))
            guard modifiers.satisfiesHotkeyRequirement else { return Defaults.Hotkey.combination }
            return HotkeyCombination(keyCode: keyCode, modifiers: modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Defaults.Hotkey.keyCodeKey)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Defaults.Hotkey.modifiersKey)
        }
    }
}
