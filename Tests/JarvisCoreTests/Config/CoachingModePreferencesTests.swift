import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachingModePreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "CoachingModePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToAutomatic() {
        #expect(CoachingModePreferences(defaults: freshDefaults()).mode == .automatic)
    }

    @Test func persistsTheChosenModeAcrossInstances() {
        let defaults = freshDefaults()
        CoachingModePreferences(defaults: defaults).mode = .manual
        #expect(CoachingModePreferences(defaults: defaults).mode == .manual)
        CoachingModePreferences(defaults: defaults).mode = .automatic
        #expect(CoachingModePreferences(defaults: defaults).mode == .automatic)
    }

    @Test func anUnknownStoredValueFallsBackToAutomatic() {
        let defaults = freshDefaults()
        defaults.set("handsFree", forKey: Defaults.Coaching.modeKey)
        #expect(CoachingModePreferences(defaults: defaults).mode == .automatic)
    }
}
