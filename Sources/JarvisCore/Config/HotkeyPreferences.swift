import Foundation

/// `@unchecked Sendable`: `shortcut` is immutable and `UserDefaults` is thread-safe.
public final class HotkeyPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    public let shortcut: CoachingShortcut
    private var keyCodeKey: String {
        switch shortcut {
        case .hint: Defaults.Hotkey.keyCodeKey
        case .explainMore: Defaults.Hotkey.explanationKeyCodeKey
        case .showCode: Defaults.Hotkey.codeKeyCodeKey
        case .previousDetail: Defaults.Hotkey.previousDetailKeyCodeKey
        case .nextDetail: Defaults.Hotkey.nextDetailKeyCodeKey
        }
    }
    private var modifiersKey: String {
        switch shortcut {
        case .hint: Defaults.Hotkey.modifiersKey
        case .explainMore: Defaults.Hotkey.explanationModifiersKey
        case .showCode: Defaults.Hotkey.codeModifiersKey
        case .previousDetail: Defaults.Hotkey.previousDetailModifiersKey
        case .nextDetail: Defaults.Hotkey.nextDetailModifiersKey
        }
    }
    private var defaultCombination: HotkeyCombination {
        switch shortcut {
        case .hint: Defaults.Hotkey.combination
        case .explainMore: Defaults.Hotkey.explanationCombination
        case .showCode: Defaults.Hotkey.codeCombination
        case .previousDetail: Defaults.Hotkey.previousDetailCombination
        case .nextDetail: Defaults.Hotkey.nextDetailCombination
        }
    }

    public init(defaults: UserDefaults = .standard, shortcut: CoachingShortcut = .hint) {
        self.defaults = defaults
        self.shortcut = shortcut
    }

    /// A stored combination failing `satisfiesHotkeyRequirement` falls back to the default, so a
    /// corrupt plist can't register an unsafe global hotkey.
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
