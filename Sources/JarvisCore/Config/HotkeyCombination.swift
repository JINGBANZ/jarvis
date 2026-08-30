import Foundation

/// One key + modifier set for the global hint hotkey: a Carbon virtual key code (layout-independent —
/// the same physical key regardless of the active input layout) plus the modifiers required.
/// Persisted via `HotkeyPreferences`; the default comes from `Defaults.Hotkey`.
public struct HotkeyCombination: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
