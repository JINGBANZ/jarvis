import Foundation

public struct HotkeyCombination: Equatable, Sendable {
    /// A Carbon virtual key code: a physical key position, independent of keyboard layout.
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
