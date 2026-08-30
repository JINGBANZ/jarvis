import Testing
import Foundation
@testable import JarvisCore

@Suite struct HotkeyPreferencesTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "HotkeyPreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsToShippedCombinationWhenUnset() {
        // Against the registry, not a literal: an absent key must return the *declared* default, so
        // an existing install sees no behavior change until it opts to rebind.
        #expect(HotkeyPreferences(defaults: freshDefaults()).combination == Defaults.Hotkey.combination)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        let combination = HotkeyCombination(keyCode: 5, modifiers: [.control, .option])
        HotkeyPreferences(defaults: d).combination = combination
        #expect(HotkeyPreferences(defaults: d).combination == combination)
    }

    @Test func bareModifiersFallBackToShippedCombination() {
        // A hand-edited or corrupted plist must never register a bare key app-wide.
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(0, forKey: Defaults.Hotkey.modifiersKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func shiftOnlyStoredModifiersFallBackToShippedCombination() {
        // A Shift-only combo is still just a typed character (e.g. Shift-3 for "#"), not a safe
        // app-wide global shortcut — `HotkeyModifiers.shift` is a nonzero raw value, so this must be
        // checked explicitly rather than only rejecting an empty set.
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(Int(HotkeyModifiers.shift.rawValue), forKey: Defaults.Hotkey.modifiersKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func controlOnlyStoredModifiersFallBackToShippedCombination() {
        // Bare Control collides with macOS's Emacs-style text-editing bindings (⌃A/⌃E/⌃K/⌃D) used
        // across every text field, so it doesn't satisfy the hotkey requirement on its own either.
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(Int(HotkeyModifiers.control.rawValue), forKey: Defaults.Hotkey.modifiersKey)
        #expect(HotkeyPreferences(defaults: d).combination == Defaults.Hotkey.combination)
    }

    @Test func partiallyStoredValueFallsBackToShippedCombination() {
        // Only one of the two keys present (e.g. a partial write) must not synthesize a combination
        // out of one stored half and one stale/default half.
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
