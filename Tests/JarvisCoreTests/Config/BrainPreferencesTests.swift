import Testing
import Foundation
@testable import JarvisCore

@Suite struct BrainPreferencesTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "BrainPreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsWhenUnset() {
        let p = BrainPreferences(defaults: freshDefaults())
        #expect(p.model == BrainModelCatalog.default)
        #expect(p.effort == .default)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        BrainPreferences(defaults: d).model = BrainModelCatalog.model(id: "gpt-5.4-mini")!
        BrainPreferences(defaults: d).effort = .high
        let reloaded = BrainPreferences(defaults: d)
        #expect(reloaded.model.id == "gpt-5.4-mini")
        #expect(reloaded.effort == .high)
    }

    @Test func unknownStoredModelFallsBackToDefault() {
        let d = freshDefaults()
        d.set("gpt-removed-from-catalog", forKey: "brain.model")
        #expect(BrainPreferences(defaults: d).model == BrainModelCatalog.default)
    }

    @Test func unknownStoredEffortFallsBackToDefault() {
        let d = freshDefaults()
        d.set("extreme", forKey: "brain.reasoningEffort")
        #expect(BrainPreferences(defaults: d).effort == .default)
    }

    @Test func modelAndEffortPersistIndependently() {
        // The effort is set once and applies to whichever model is selected: changing the model must
        // not disturb the stored effort.
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.effort = .medium
        p.model = BrainModelCatalog.model(id: "gpt-5.4-nano")!
        #expect(p.effort == .medium)
    }
}
