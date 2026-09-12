import Foundation

/// Persisted binding for one coaching shortcut. Backed by UserDefaults; keys and the shipped
/// defaults come from `Defaults.Hotkey`. Foundation-only so it stays unit-testable in JarvisCore;
/// inject a `UserDefaults(suiteName:)` in tests. Mirrors `ScreenCapturePreferences`.
///
/// `@unchecked Sendable`: the stored shortcut is immutable, and `UserDefaults`
/// is documented thread-safe — both `HotkeyController` and the Settings section that edits this read
/// and write on the main actor only.
public final class HotkeyPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    public let shortcut: CoachingShortcut
    private var keyCodeKey: String {
        switch shortcut {
        case .hint: Defaults.Hotkey.keyCodeKey
        case .explainMore: Defaults.Hotkey.explanationKeyCodeKey
        case .showCode: Defaults.Hotkey.codeKeyCodeKey
        }
    }
    private var modifiersKey: String {
        switch shortcut {
        case .hint: Defaults.Hotkey.modifiersKey
        case .explainMore: Defaults.Hotkey.explanationModifiersKey
        case .showCode: Defaults.Hotkey.codeModifiersKey
        }
    }
    private var defaultCombination: HotkeyCombination {
        switch shortcut {
        case .hint: Defaults.Hotkey.combination
        case .explainMore: Defaults.Hotkey.explanationCombination
        case .showCode: Defaults.Hotkey.codeCombination
        }
    }

    public init(defaults: UserDefaults = .standard, shortcut: CoachingShortcut = .hint) {
        self.defaults = defaults
        self.shortcut = shortcut
    }

    /// Absent, or a stored combination whose modifiers don't satisfy `satisfiesHotkeyRequirement`
    /// (a hand-edited or corrupted plist — the shortcut recorder never writes one), falls back to the
    /// shipped default rather than registering an unsafe combination app-wide.
    public var combination: HotkeyCombination {
        get {
            guard defaults.object(forKey: keyCodeKey) != nil,
                  defaults.object(forKey: modifiersKey) != nil else {
                return defaultCombination
            }
            let keyCode = UInt32(
                truncatingIfNeeded: defaults.integer(forKey: keyCodeKey))
            let modifiers = HotkeyModifiers(rawValue: UInt32(
                truncatingIfNeeded: defaults.integer(forKey: modifiersKey)))
            guard modifiers.satisfiesHotkeyRequirement else { return defaultCombination }
            return HotkeyCombination(keyCode: keyCode, modifiers: modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: keyCodeKey)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: modifiersKey)
        }
    }
}
