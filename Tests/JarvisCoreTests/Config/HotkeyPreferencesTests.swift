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
        let combination = HotkeyCombination(keyCode: 5, modifiers: [.control, .shift])
        HotkeyPreferences(defaults: d).combination = combination
        #expect(HotkeyPreferences(defaults: d).combination == combination)
    }

    @Test func invalidStoredModifiersFallBackToShippedCombination() {
        // A hand-edited or corrupted plist must never register a bare key app-wide.
        let d = freshDefaults()
        d.set(5, forKey: Defaults.Hotkey.keyCodeKey)
        d.set(0, forKey: Defaults.Hotkey.modifiersKey)
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
}
