import Testing
import Foundation
@testable import JarvisCore

@Suite struct HotkeyPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "HotkeyPreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func navigationBindingsPersistIndependentlyFromCoachingBindings() {
        let defaults = freshDefaults()
        let previous = HotkeyPreferences(defaults: defaults, shortcut: .previousDetail)
        let next = HotkeyPreferences(defaults: defaults, shortcut: .nextDetail)
        #expect(previous.combination == HotkeyCombination(keyCode: 123, modifiers: [.command, .option]))
        #expect(next.combination == HotkeyCombination(keyCode: 124, modifiers: [.command, .option]))
        previous.combination = HotkeyCombination(keyCode: 5, modifiers: [.command, .shift])
        next.combination = HotkeyCombination(keyCode: 6, modifiers: [.command, .shift])
        #expect(HotkeyPreferences(defaults: defaults, shortcut: .previousDetail).combination
            == HotkeyCombination(keyCode: 5, modifiers: [.command, .shift]))
        #expect(HotkeyPreferences(defaults: defaults, shortcut: .nextDetail).combination
            == HotkeyCombination(keyCode: 6, modifiers: [.command, .shift]))
        #expect(HotkeyPreferences(defaults: defaults).combination == Defaults.Hotkey.combination)
        #expect(CoachingShortcut.previousDetail.triggerReason == nil)
        #expect(CoachingShortcut.nextDetail.triggerReason == nil)
    }

    @Test func defaultsToShippedCombinationWhenUnset() {
        #expect(HotkeyPreferences(defaults: freshDefaults()).combination == Defaults.Hotkey.combination)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        let combination = HotkeyCombination(keyCode: 5, modifiers: [.control, .option])
        HotkeyPreferences(defaults: d).combination = combination
        #expect(HotkeyPreferences(defaults: d).combination == combination)
    }

    @Test func bareModifiersFallBackToShippedCombination() {
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(0, forKey: Defaults.Hotkey.modifiersKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func shiftOnlyStoredModifiersFallBackToShippedCombination() {
        // Shift plus a key is still a typed character, e.g. Shift-3 for "#".
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(Int(HotkeyModifiers.shift.rawValue), forKey: Defaults.Hotkey.modifiersKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func controlOnlyStoredModifiersFallBackToShippedCombination() {
        // Bare Control collides with the macOS text-editing bindings (⌃A, ⌃E, ⌃K, ⌃D).
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(Int(HotkeyModifiers.control.rawValue), forKey: Defaults.Hotkey.modifiersKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func partiallyStoredValueFallsBackToShippedCombination() {
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func modifiersCombineDistinctBits() {
        let modifiers: HotkeyModifiers = [.command, .option]
        #expect(modifiers.contains(.command))
        #expect(modifiers.contains(.option))
        #expect(!modifiers.contains(.control))
        #expect(!modifiers.contains(.shift))
    }

    @Test func satisfiesHotkeyRequirementNeedsCommandOrOption() {
        #expect(HotkeyModifiers.command.satisfiesHotkeyRequirement)
        #expect(HotkeyModifiers.option.satisfiesHotkeyRequirement)
        #expect(([.command, .shift] as HotkeyModifiers).satisfiesHotkeyRequirement)
        #expect(([.option, .control] as HotkeyModifiers).satisfiesHotkeyRequirement)
        #expect(!HotkeyModifiers.shift.satisfiesHotkeyRequirement)
        #expect(!HotkeyModifiers.control.satisfiesHotkeyRequirement)
        #expect(!([.shift, .control] as HotkeyModifiers).satisfiesHotkeyRequirement)
        #expect(!HotkeyModifiers().satisfiesHotkeyRequirement)
    }
}
