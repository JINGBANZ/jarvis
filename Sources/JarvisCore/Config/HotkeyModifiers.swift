import Foundation

/// Modifier keys the global hint hotkey can require. Raw values match Carbon's `cmdKey`/`shiftKey`/
/// `optionKey`/`controlKey` masks bit-for-bit, so `HotkeyController` (JarvisApp) can hand `rawValue`
/// straight to `RegisterEventHotKey` with no translation table. Kept Foundation-only here — the
/// Carbon import stays in JarvisApp, alongside the rest of the OS-bound hotkey code.
public struct HotkeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 8)
    public static let shift = HotkeyModifiers(rawValue: 1 << 9)
    public static let option = HotkeyModifiers(rawValue: 1 << 11)
    public static let control = HotkeyModifiers(rawValue: 1 << 12)
}
