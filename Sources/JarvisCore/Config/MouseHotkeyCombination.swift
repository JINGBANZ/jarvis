import Foundation

public struct MouseHotkeyCombination: Equatable, Sendable {
    public let button: Int
    public let modifiers: HotkeyModifiers

    public init(button: Int, modifiers: HotkeyModifiers) {
        self.button = button
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        let supported: HotkeyModifiers = [.command, .option, .control, .shift]
        return (0...31).contains(button)
            && modifiers.subtracting(supported).isEmpty
            && (button >= 2 || modifiers.satisfiesHotkeyRequirement)
    }
}
