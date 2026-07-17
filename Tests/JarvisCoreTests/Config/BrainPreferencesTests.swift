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

    @Test func providerDefaultsToOpenAIAndRoundTrips() {
        let d = freshDefaults()
        #expect(BrainPreferences(defaults: d).provider == .openAI)
        BrainPreferences(defaults: d).provider = .claudeCode
        #expect(BrainPreferences(defaults: d).provider == .claudeCode)
    }

    @Test func unknownStoredProviderFallsBackToOpenAI() {
        let d = freshDefaults()
        d.set("gemini-cli", forKey: "brain.provider")
        #expect(BrainPreferences(defaults: d).provider == .openAI)
    }

    @Test func eachProviderRemembersItsOwnModel() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.setModel(BrainModelCatalog.model(id: "gpt-5.4-mini", for: .openAI)!, for: .openAI)
        p.setModel(BrainModelCatalog.model(id: "opus", for: .claudeCode)!, for: .claudeCode)
        // Switching providers keeps each one's model; the OpenAI model stays under the legacy
        // "brain.model" key so pre-provider installs keep their selection.
        #expect(p.model(for: .openAI).id == "gpt-5.4-mini")
        #expect(p.model(for: .claudeCode).id == "opus")
        #expect(d.string(forKey: "brain.model") == "gpt-5.4-mini")
        p.provider = .claudeCode
        #expect(p.model.id == "opus")
    }

    @Test func modelStoredForOneProviderNeverLeaksToAnother() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.setModel(BrainModelCatalog.model(id: "haiku", for: .claudeCode)!, for: .claudeCode)
        // A claude alias is not a valid codex/openai model — those providers stay on their defaults.
        #expect(p.model(for: .openAI) == BrainModelCatalog.default)
        #expect(p.model(for: .codexCLI) == BrainModelCatalog.defaultModel(for: .codexCLI))
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
