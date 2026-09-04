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
        #expect(p.model == BrainModelCatalog.defaultModel(for: .openAI))
        #expect(p.effort == Defaults.Brain.effort)
        #expect(p.primaryTarget == BrainTarget(
            provider: .openAI,
            modelID: BrainModelCatalog.defaultModel(for: .openAI).id))
        #expect(p.fallbackTargets.isEmpty)
        #expect(p.route.targets == [p.primaryTarget])
        #expect(p.primaryTarget.provider == Defaults.Brain.provider)
        // Absence is the persisted representation of Automatic, not an explicit override.
        #expect(p.interviewFormat == nil)
    }

    @Test func interviewFormatOverrideRoundTripsAndClearsBackToAutomatic() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.interviewFormat = .systemDesign
        #expect(BrainPreferences(defaults: d).interviewFormat == .systemDesign)
        p.interviewFormat = nil
        #expect(BrainPreferences(defaults: d).interviewFormat == nil)
        #expect(d.string(forKey: "brain.interviewFormat") == nil)
    }

    @Test func unknownStoredInterviewFormatFallsBackToAutomatic() {
        let d = freshDefaults()
        d.set("architecture-review", forKey: "brain.interviewFormat")
        #expect(BrainPreferences(defaults: d).interviewFormat == nil)
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
        #expect(
            BrainPreferences(defaults: d).model
                == BrainModelCatalog.defaultModel(for: .openAI))
        #expect(d.string(forKey: "brain.model") == "gpt-removed-from-catalog")
    }

    @Test func unknownStoredEffortFallsBackToDefault() {
        let d = freshDefaults()
        d.set("extreme", forKey: "brain.reasoningEffort")
        #expect(BrainPreferences(defaults: d).effort == Defaults.Brain.effort)
    }

    @Test func providerDefaultsToOpenAIAndRoundTrips() {
        let d = freshDefaults()
        #expect(BrainPreferences(defaults: d).provider == .openAI)
        #expect(BrainPreferences(defaults: d).fallbackTargets.isEmpty)
        BrainPreferences(defaults: d).provider = .claudeCode
        #expect(BrainPreferences(defaults: d).provider == .claudeCode)
        #expect(BrainPreferences(defaults: d).primaryTarget.provider == .claudeCode)
        #expect(BrainPreferences(defaults: d).route.primary.provider == .claudeCode)
    }

    @Test func unknownStoredProviderFallsBackToOpenAI() {
        let d = freshDefaults()
        d.set("gemini-cli", forKey: "brain.provider")
        #expect(BrainPreferences(defaults: d).provider == .openAI)
        #expect(BrainPreferences(defaults: d).primaryTarget.provider == .openAI)
    }

    @Test func orderedFallbackTargetsRoundTrip() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let targets = [
            BrainTarget(provider: .claudeCode, modelID: "claude-opus-5"),
            BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-terra"),
            BrainTarget(provider: .claudeCode, modelID: "claude-haiku-4-5"),
        ]
        p.fallbackTargets = targets
        #expect(BrainPreferences(defaults: d).fallbackTargets == targets)
        #expect(BrainPreferences(defaults: d).route.targets == [p.primaryTarget] + targets)
    }

    @Test func storedFallbackTargetsAreSanitizedWithoutChangingValidOrder() {
        let d = freshDefaults()
        d.set([
            ["provider": "future-provider", "modelID": "future-model"],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "claude-opus-5"],
            [
                "provider": BrainProvider.openAI.rawValue,
                "modelID": BrainModelCatalog.defaultModel(for: .openAI).id,
            ],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "removed-model"],
            ["provider": BrainProvider.openAI.rawValue, "modelID": "gpt-5.4-nano"],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "opus"],
            ["provider": BrainProvider.codexCLI.rawValue, "modelID": ""],
            ["provider": BrainProvider.codexCLI.rawValue, "modelID": "gpt-5.6-terra"],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "claude-opus-5"],
            ["provider": BrainProvider.claudeCode.rawValue, "modelID": "claude-haiku-4-5"],
        ], forKey: "brain.fallbackTargets")

        let expected = [
            BrainTarget(provider: .claudeCode, modelID: "claude-opus-5"),
            BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-terra"),
            BrainTarget(provider: .claudeCode, modelID: "claude-haiku-4-5"),
        ]
        #expect(BrainPreferences(defaults: d).fallbackTargets == expected)
        #expect((d.array(forKey: "brain.fallbackTargets") ?? []).count == expected.count)
    }

    @Test func primaryChangeRemovesOnlyItsExactDuplicate() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let claudeDefault = BrainModelCatalog.defaultModel(for: .claudeCode)
        let claudeAlternate = BrainModelCatalog.models(for: .claudeCode)[1]
        p.fallbackTargets = [
            BrainTarget(provider: .claudeCode, modelID: claudeAlternate.id),
            BrainTarget(provider: .claudeCode, modelID: claudeDefault.id),
        ]

        p.provider = .claudeCode

        #expect(p.primaryTarget == BrainTarget(
            provider: .claudeCode, modelID: claudeDefault.id))
        #expect(p.fallbackTargets == [
            BrainTarget(provider: .claudeCode, modelID: claudeAlternate.id)
        ])
    }

    @Test func routeSetterPersistsPrimaryAndFallbackTargetsWithoutRuntimeState() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let route = BrainRoute(
            primary: BrainTarget(provider: .codexCLI, modelID: "gpt-5.5"),
            fallbackTargets: [
                BrainTarget(provider: .openAI, modelID: "gpt-5.4-mini"),
                BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-terra"),
            ])

        p.route = route

        #expect(BrainPreferences(defaults: d).route == route)
        #expect(d.object(forKey: "brain.routeCursor") == nil)
        #expect(d.object(forKey: "brain.routeFailureCount") == nil)
    }

    @Test func atomicPrimaryTargetChangePreservesADifferentModelFromTheSameProvider() {
        let p = BrainPreferences(defaults: freshDefaults())
        p.setModel(
            BrainModelCatalog.model(id: "claude-sonnet-5", for: .claudeCode)!,
            for: .claudeCode)
        p.fallbackTargets = [
            BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5"),
        ]

        p.route = BrainRoute(
            primary: BrainTarget(provider: .claudeCode, modelID: "claude-opus-5"),
            fallbackTargets: p.fallbackTargets)

        #expect(p.primaryTarget == BrainTarget(
            provider: .claudeCode, modelID: "claude-opus-5"))
        #expect(p.fallbackTargets == [
            BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5"),
        ])
    }

    @Test func eachProviderRemembersItsOwnModel() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.setModel(BrainModelCatalog.model(id: "gpt-5.4-mini", for: .openAI)!, for: .openAI)
        p.setModel(
            BrainModelCatalog.model(id: "claude-opus-5", for: .claudeCode)!,
            for: .claudeCode)
        // Switching providers keeps each one's model; the OpenAI model stays under the legacy
        // "brain.model" key so pre-provider installs keep their selection.
        #expect(p.model(for: .openAI).id == "gpt-5.4-mini")
        #expect(p.model(for: .claudeCode).id == "claude-opus-5")
        #expect(d.string(forKey: "brain.model") == "gpt-5.4-mini")
        p.provider = .claudeCode
        #expect(p.model.id == "claude-opus-5")
    }

    @Test func modelStoredForOneProviderNeverLeaksToAnother() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.setModel(
            BrainModelCatalog.model(id: "claude-haiku-4-5", for: .claudeCode)!,
            for: .claudeCode)
        // A Claude model is not a valid Codex/OpenAI model — those providers stay on their defaults.
        #expect(p.model(for: .openAI) == BrainModelCatalog.defaultModel(for: .openAI))
        #expect(p.model(for: .codexCLI) == BrainModelCatalog.defaultModel(for: .codexCLI))
    }

    @Test func everySelectableModelReusesTheExistingReasoningEffort() {
        for provider in BrainProvider.allCases {
            for model in BrainModelCatalog.models(for: provider) {
                let p = BrainPreferences(defaults: freshDefaults())
                p.provider = provider
                p.effort = .medium
                p.model = model
                #expect(p.model == model)
                #expect(p.effort == .medium)
            }
        }
    }
}
