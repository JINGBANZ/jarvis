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
        #expect(p.primaryTarget == BrainTarget(provider: .openAI, modelID: BrainModelCatalog.default.id))
        #expect(p.fallbackTargets.isEmpty)
        #expect(p.route.targets == [p.primaryTarget])
        #expect(p.configuredPrimaryTarget == nil)
        #expect(p.configuredRoute == nil)
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
        #expect(BrainPreferences(defaults: d).fallbackTargets.isEmpty)
        BrainPreferences(defaults: d).provider = .claudeCode
        #expect(BrainPreferences(defaults: d).provider == .claudeCode)
        #expect(BrainPreferences(defaults: d).configuredPrimaryTarget?.provider == .claudeCode)
        #expect(BrainPreferences(defaults: d).configuredRoute?.primary.provider == .claudeCode)
    }

    @Test func unknownStoredProviderFallsBackToOpenAI() {
        let d = freshDefaults()
        d.set("gemini-cli", forKey: "brain.provider")
        #expect(BrainPreferences(defaults: d).provider == .openAI)
        #expect(BrainPreferences(defaults: d).configuredPrimaryTarget == nil)
    }

    @Test func orderedFallbackTargetsRoundTrip() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let targets = [
            BrainTarget(provider: .claudeCode, modelID: "opus"),
            BrainTarget(provider: .codexCLI, modelID: ""),
            BrainTarget(provider: .claudeCode, modelID: "haiku"),
        ]
        p.fallbackTargets = targets
        #expect(BrainPreferences(defaults: d).fallbackTargets == targets)
        #expect(BrainPreferences(defaults: d).route.targets == [p.primaryTarget] + targets)
    }

    @Test func storedFallbackTargetsAreSanitizedWithoutChangingValidOrder() {
        let d = freshDefaults()
        d.set([
            ["provider": "future-provider", "modelID": "future-model"],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "opus"],
            ["provider": BrainProvider.openAI.rawValue, "modelID": BrainModelCatalog.default.id],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "removed-model"],
            ["provider": BrainProvider.codexCLI.rawValue, "modelID": ""],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "opus"],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "haiku"],
        ], forKey: "brain.fallbackTargets")

        let expected = [
            BrainTarget(provider: .claudeCode, modelID: "opus"),
            BrainTarget(provider: .codexCLI, modelID: ""),
            BrainTarget(provider: .claudeCode, modelID: "haiku"),
        ]
        #expect(BrainPreferences(defaults: d).fallbackTargets == expected)
        #expect((d.array(forKey: "brain.fallbackTargets") ?? []).count == expected.count)
    }

    @Test func legacyScalarFallbackMigratesWithRememberedModel() {
        let d = freshDefaults()
        d.set(BrainProvider.claudeCode.rawValue, forKey: "brain.fallbackProvider")
        d.set("opus", forKey: "brain.model.\(BrainProvider.claudeCode.rawValue)")

        let p = BrainPreferences(defaults: d)
        #expect(p.fallbackTargets == [
            BrainTarget(provider: .claudeCode, modelID: "opus")
        ])
        #expect(d.object(forKey: "brain.fallbackTargets") != nil)
        #expect(d.object(forKey: "brain.fallbackProvider") == nil)
        #expect(BrainPreferences(defaults: d).fallbackTargets == p.fallbackTargets)
    }

    @Test func invalidLegacyFallbackMigratesToEmptyRoute() {
        let d = freshDefaults()
        d.set("future-provider", forKey: "brain.fallbackProvider")
        #expect(BrainPreferences(defaults: d).fallbackTargets.isEmpty)
        #expect(d.object(forKey: "brain.fallbackTargets") != nil)
        #expect(d.object(forKey: "brain.fallbackProvider") == nil)
    }

    @Test func primaryChangeRemovesOnlyItsExactDuplicate() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.fallbackTargets = [
            BrainTarget(provider: .claudeCode, modelID: "sonnet"),
            BrainTarget(provider: .claudeCode, modelID: "opus"),
        ]

        p.provider = .claudeCode

        #expect(p.primaryTarget == BrainTarget(provider: .claudeCode, modelID: "sonnet"))
        #expect(p.fallbackTargets == [
            BrainTarget(provider: .claudeCode, modelID: "opus")
        ])
    }

    @Test func routeSetterPersistsPrimaryAndFallbackTargetsWithoutRuntimeState() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let route = BrainRoute(
            primary: BrainTarget(provider: .codexCLI, modelID: "gpt-5.5"),
            fallbackTargets: [
                BrainTarget(provider: .openAI, modelID: "gpt-5.4-mini"),
                BrainTarget(provider: .codexCLI, modelID: ""),
            ])

        p.route = route

        #expect(BrainPreferences(defaults: d).route == route)
        #expect(BrainPreferences(defaults: d).configuredRoute == route)
        #expect(d.object(forKey: "brain.routeCursor") == nil)
        #expect(d.object(forKey: "brain.routeFailureCount") == nil)
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
