import Testing
import Foundation
@testable import JarvisCore

@Suite struct BrainPreferencesTests {
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
    }

    /// Storing what is off keeps a tool added in a later version on by default.
    @Test func disabledToolsRoundTripAndDefaultToNothingSwitchedOff() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        #expect(p.disabledTools.isEmpty)

        p.disabledTools = ["search_prep_notes"]

        #expect(BrainPreferences(defaults: d).disabledTools == ["search_prep_notes"])
        #expect(d.stringArray(forKey: Defaults.Brain.disabledToolsKey) == ["search_prep_notes"])
    }

    @Test func disabledSkillsRoundTripAndDefaultToNothingSwitchedOff() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        #expect(p.disabledSkills.isEmpty)

        p.disabledSkills = ["system-design"]

        #expect(BrainPreferences(defaults: d).disabledSkills == ["system-design"])
        #expect(d.stringArray(forKey: Defaults.Brain.disabledSkillsKey) == ["system-design"])
    }

    @Test func theToolsASessionNeedsAreDroppedOnWrite() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)

        p.disabledTools = CoachCapabilities.fixedToolNames.union(["search_prep_notes"])

        #expect(p.disabledTools == ["search_prep_notes"])
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        BrainPreferences(defaults: d).model = BrainModelCatalog.model(id: "gpt-5.4-mini")!
        BrainPreferences(defaults: d).effort = .high
        let reloaded = BrainPreferences(defaults: d)
        #expect(reloaded.model.id == "gpt-5.4-mini")
        #expect(reloaded.effort == .high)
    }

    @Test func latestModelsAndExistingFableRoundTripWithoutChangingEffort() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-6-astra")
        let fallbacks = [
            BrainTarget(provider: .codexSubscription, modelID: "gpt-6-astra"),
            BrainTarget(provider: .claudeSubscription, modelID: "claude-fable-5-1"),
            BrainTarget(provider: .claudeSubscription, modelID: "claude-fable-5"),
        ]
        p.route = BrainRoute(primary: primary, fallbackTargets: fallbacks)
        p.effort = .none
        let reloaded = BrainPreferences(defaults: d)
        #expect(reloaded.route.targets == [primary] + fallbacks)
        #expect(reloaded.effort == .none)
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
        BrainPreferences(defaults: d).provider = .claudeSubscription
        #expect(BrainPreferences(defaults: d).provider == .claudeSubscription)
        #expect(BrainPreferences(defaults: d).primaryTarget.provider == .claudeSubscription)
        #expect(BrainPreferences(defaults: d).route.primary.provider == .claudeSubscription)
    }

    @Test func unknownStoredProviderFallsBackToOpenAI() {
        let d = freshDefaults()
        d.set("gemini-cli", forKey: "brain.provider")
        #expect(BrainPreferences(defaults: d).provider == .openAI)
        #expect(BrainPreferences(defaults: d).primaryTarget.provider == .openAI)
    }

    @Test func savedLocalCLIProvidersReadAsUnknown() {
        let d = freshDefaults()
        d.set("claude-code", forKey: "brain.provider")
        d.set([
            ["provider": "codex-cli", "modelID": "gpt-5.6-sol"],
            ["provider": BrainProvider.codexSubscription.rawValue, "modelID": "gpt-5.6-sol"],
        ], forKey: "brain.fallbackTargets")

        let p = BrainPreferences(defaults: d)
        #expect(p.primaryTarget.provider == Defaults.Brain.provider)
        #expect(p.fallbackTargets == [BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-sol")])
    }

    @Test func orderedFallbackTargetsRoundTrip() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let targets = [
            BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"),
            BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-terra"),
            BrainTarget(provider: .claudeSubscription, modelID: "claude-haiku-4-5-20251001"),
        ]
        p.fallbackTargets = targets
        #expect(BrainPreferences(defaults: d).fallbackTargets == targets)
        #expect(BrainPreferences(defaults: d).route.targets == [p.primaryTarget] + targets)
    }

    @Test func storedFallbackTargetsAreSanitizedWithoutChangingValidOrder() {
        let d = freshDefaults()
        d.set([
            ["provider": "future-provider", "modelID": "future-model"],
            ["provider": BrainProvider.claudeSubscription.rawValue, "modelID": "claude-opus-5"],
            [
                "provider": BrainProvider.openAI.rawValue,
                "modelID": BrainModelCatalog.defaultModel(for: .openAI).id,
            ],
            ["provider": BrainProvider.claudeSubscription.rawValue, "modelID": "removed-model"],
            ["provider": BrainProvider.openAI.rawValue, "modelID": "gpt-5.4-nano"],
            ["provider": BrainProvider.claudeSubscription.rawValue, "modelID": "opus"],
            ["provider": BrainProvider.codexSubscription.rawValue, "modelID": ""],
            ["provider": BrainProvider.codexSubscription.rawValue, "modelID": "gpt-5.6-terra"],
            ["provider": BrainProvider.claudeSubscription.rawValue, "modelID": "claude-opus-5"],
            ["provider": BrainProvider.claudeSubscription.rawValue, "modelID": "claude-haiku-4-5-20251001"],
        ], forKey: "brain.fallbackTargets")

        let expected = [
            BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"),
            BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-terra"),
            BrainTarget(provider: .claudeSubscription, modelID: "claude-haiku-4-5-20251001"),
        ]
        #expect(BrainPreferences(defaults: d).fallbackTargets == expected)
        #expect((d.array(forKey: "brain.fallbackTargets") ?? []).count == expected.count)
    }

    @Test func primaryChangeRemovesOnlyItsExactDuplicate() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let claudeDefault = BrainModelCatalog.defaultModel(for: .claudeSubscription)
        let claudeAlternate = BrainModelCatalog.models(for: .claudeSubscription)[1]
        p.fallbackTargets = [
            BrainTarget(provider: .claudeSubscription, modelID: claudeAlternate.id),
            BrainTarget(provider: .claudeSubscription, modelID: claudeDefault.id),
        ]

        p.provider = .claudeSubscription

        #expect(p.primaryTarget == BrainTarget(
            provider: .claudeSubscription, modelID: claudeDefault.id))
        #expect(p.fallbackTargets == [
            BrainTarget(provider: .claudeSubscription, modelID: claudeAlternate.id)
        ])
    }

    @Test func routeSetterPersistsPrimaryAndFallbackTargetsWithoutRuntimeState() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        let route = BrainRoute(
            primary: BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"),
            fallbackTargets: [
                BrainTarget(provider: .openAI, modelID: "gpt-5.4-mini"),
                BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-terra"),
            ])

        p.route = route

        #expect(BrainPreferences(defaults: d).route == route)
        #expect(d.object(forKey: "brain.routeCursor") == nil)
        #expect(d.object(forKey: "brain.routeFailureCount") == nil)
    }

    @Test func atomicPrimaryTargetChangePreservesADifferentModelFromTheSameProvider() {
        let p = BrainPreferences(defaults: freshDefaults())
        p.setModel(
            BrainModelCatalog.model(id: "claude-sonnet-5", for: .claudeSubscription)!,
            for: .claudeSubscription)
        p.fallbackTargets = [
            BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"),
        ]

        p.route = BrainRoute(
            primary: BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"),
            fallbackTargets: p.fallbackTargets)

        #expect(p.primaryTarget == BrainTarget(
            provider: .claudeSubscription, modelID: "claude-opus-5"))
        #expect(p.fallbackTargets == [
            BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"),
        ])
    }

    @Test func eachProviderRemembersItsOwnModel() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.setModel(BrainModelCatalog.model(id: "gpt-5.4-mini", for: .openAI)!, for: .openAI)
        p.setModel(
            BrainModelCatalog.model(id: "claude-opus-5", for: .claudeSubscription)!,
            for: .claudeSubscription)
        // OpenAI stays on the unscoped key so existing installs keep their selection.
        #expect(p.model(for: .openAI).id == "gpt-5.4-mini")
        #expect(p.model(for: .claudeSubscription).id == "claude-opus-5")
        #expect(d.string(forKey: "brain.model") == "gpt-5.4-mini")
        p.provider = .claudeSubscription
        #expect(p.model.id == "claude-opus-5")
    }

    @Test func modelStoredForOneProviderNeverLeaksToAnother() {
        let d = freshDefaults()
        let p = BrainPreferences(defaults: d)
        p.setModel(
            BrainModelCatalog.model(id: "claude-haiku-4-5-20251001", for: .claudeSubscription)!,
            for: .claudeSubscription)
        #expect(p.model(for: .openAI) == BrainModelCatalog.defaultModel(for: .openAI))
        #expect(p.model(for: .codexSubscription) == BrainModelCatalog.defaultModel(for: .codexSubscription))
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
