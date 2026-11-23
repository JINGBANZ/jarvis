import Testing
@testable import JarvisCore

@Suite struct BrainModelCatalogTests {
    @Test func catalogIsNonEmptyWithUniqueIDs() {
        let ids = BrainModelCatalog.all.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test func sharedOpenAIListIncludesLatestModel() {
        #expect(BrainModelCatalog.all.map(\.id) == [
            "gpt-6.2-sol",
            "gpt-6.2-astra",
            "gpt-6.1-terra",
            "gpt-6-luna",
            "gpt-5.4-mini",
        ])
    }

    @Test func claudeSubscriptionListsOnlyTheLatestSupportedReleaseOfEachLine() {
        #expect(BrainModelCatalog.models(for: .claudeSubscription).map(\.id) == [
            "claude-opus-5-5",
            "claude-sonnet-5-5",
            "claude-fable-5-2",
            "claude-haiku-5-5",
        ])
    }

    @Test func openAIAndCodexSubscriptionShareTheSameCatalog() {
        #expect(BrainModelCatalog.models(for: .openAI) == BrainModelCatalog.all)
        #expect(BrainModelCatalog.models(for: .codexSubscription) == BrainModelCatalog.all)
    }

    @Test func lookupFindsKnownModelsAndRejectsUnknown() {
        #expect(BrainModelCatalog.model(id: "gpt-6.2-sol")?.displayName == "GPT-6.2 Sol")
        #expect(BrainModelCatalog.model(id: "gpt-6.1-terra")?.displayName == "GPT-6.1 Terra")
        #expect(BrainModelCatalog.model(id: "gpt-5.4-mini")?.displayName == "GPT-5.4 mini")
        #expect(BrainModelCatalog.model(id: "gpt-9000") == nil)
        #expect(BrainModelCatalog.model(id: "gpt-6.1-sol") == nil)
        #expect(BrainModelCatalog.model(id: "gpt-6-astra") == nil)
        #expect(BrainModelCatalog.model(id: "gpt-5.6-terra") == nil)
        #expect(BrainModelCatalog.model(id: "claude-sonnet-5", for: .claudeSubscription) == nil)
        #expect(BrainModelCatalog.model(id: "claude-fable-5-1", for: .claudeSubscription) == nil)
        #expect(BrainModelCatalog.model(id: "claude-haiku-4-5-20251001", for: .claudeSubscription) == nil)
    }

    @Test func everyProviderUsesItsFirstCatalogEntryAsDefault() {
        for provider in BrainProvider.allCases {
            let models = BrainModelCatalog.models(for: provider)
            #expect(!models.isEmpty)
            #expect(Set(models.map(\.id)).count == models.count)
            #expect(models.allSatisfy { !$0.id.isEmpty })
            #expect(BrainModelCatalog.defaultModel(for: provider) == models.first)
        }
    }

    @Test func providerDefaultsFollowCatalogOrder() {
        #expect(BrainModelCatalog.defaultModel(for: .openAI).id == "gpt-6.2-sol")
        #expect(BrainModelCatalog.defaultModel(for: .codexSubscription).id == "gpt-6.2-sol")
        #expect(BrainModelCatalog.defaultModel(for: .claudeSubscription).id == "claude-opus-5-5")
    }

    @Test func perProviderLookupIsScopedToThatProvider() {
        #expect(
            BrainModelCatalog.model(id: "claude-opus-5-5", for: .claudeSubscription)?.displayName
                == "Claude Opus 5.5")
        #expect(BrainModelCatalog.model(id: "sonnet", for: .claudeSubscription) == nil)
        #expect(BrainModelCatalog.model(id: "", for: .codexSubscription) == nil)
        #expect(BrainModelCatalog.model(id: "gpt-6.2-sol", for: .claudeSubscription) == nil)
    }

    @Test func summarizerModelsUseVerifiedProviderBehavior() {
        #expect(BrainModelCatalog.summarizerModelID(for: .openAI) == "gpt-5.4-mini")
        #expect(BrainModelCatalog.summarizerModelID(for: .claudeSubscription) == "claude-haiku-5-5")
        #expect(BrainModelCatalog.summarizerModelID(for: .codexSubscription) == "")
    }

    @Test func geminiListsStableGemini4AndFlashModels() {
        #expect(BrainModelCatalog.models(for: .gemini).map(\.id) == [
            "gemini-3.8-flash", "gemini-4-hydrogen", "gemini-4-neon", "gemini-4-carbon",
            "gemini-4-argon", "gemini-3.6-flash", "gemini-3.5-flash-lite",
        ])
        #expect(BrainModelCatalog.defaultModel(for: .gemini).id == "gemini-3.8-flash")
        #expect(BrainModelCatalog.summarizerModelID(for: .gemini) == "gemini-3.5-flash-lite")
    }

    @Test func effortFloorsAreModelData() {
        let floored: Set<String> = [
            "gpt-6.2-sol", "gpt-6.2-astra", "gemini-3.8-flash",
            "gemini-4-hydrogen", "gemini-4-neon", "gemini-4-carbon", "gemini-4-argon",
        ]
        for provider in BrainProvider.allCases {
            for model in BrainModelCatalog.models(for: provider) {
                #expect(model.reasoningEffortFloor == (floored.contains(model.id) ? .low : nil),
                        "\(provider.rawValue) \(model.id)")
            }
        }
    }
}
