import Foundation

/// Raw values match Carbon's `cmdKey`/`shiftKey`/`optionKey`/`controlKey` masks, so `rawValue` goes
/// straight to `RegisterEventHotKey`.
public struct HotkeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 8)
    public static let shift = HotkeyModifiers(rawValue: 1 << 9)
    public static let option = HotkeyModifiers(rawValue: 1 << 11)
    public static let control = HotkeyModifiers(rawValue: 1 << 12)

    /// Requires ⌘ or ⌥: bare ⇧ still types a character, and bare ⌃ collides with macOS text-editing
    /// bindings such as ⌃A and ⌃E.
    public var satisfiesHotkeyRequirement: Bool {
        contains(.command) || contains(.option)
    }
}
