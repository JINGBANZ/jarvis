import Foundation

public struct MouseShortcutRouter: Sendable {
    public enum Phase: Sendable { case down, up, drag }
    public enum Outcome: Equatable, Sendable {
        case passThrough
        case consume
        case trigger(CoachingShortcut)
    }

    public private(set) var bindings: [CoachingShortcut: MouseHotkeyCombination] = [:]
    private var consumedButtons: Set<Int> = []

    public init() {}

    @discardableResult
    public mutating func bind(_ combination: MouseHotkeyCombination?, to shortcut: CoachingShortcut) -> Bool {
        if let combination {
            guard combination.isValid,
                  !bindings.contains(where: { $0.key != shortcut && $0.value == combination }) else {
                return false
            }
        }
        bindings[shortcut] = combination
        return true
    }

    public mutating func resetPressedButtons() {
        consumedButtons.removeAll()
    }

    public mutating func handle(
        button: Int, modifiers: HotkeyModifiers, phase: Phase, enabled: Set<CoachingShortcut>
    ) -> Outcome {
        // Finish a swallowed click even if modifiers, settings, or session state changed mid-press.
        if consumedButtons.contains(button) {
            if phase == .up { consumedButtons.remove(button) }
            return .consume
        }
        guard phase == .down,
              let shortcut = bindings.first(where: {
                  enabled.contains($0.key) && $0.value == MouseHotkeyCombination(button: button, modifiers: modifiers)
              })?.key else { return .passThrough }
        consumedButtons.insert(button)
        return .trigger(shortcut)
    }
}
