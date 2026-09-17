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
            "gpt-5.6-sol",
            "gpt-6-astra",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
        ])
    }

    /// CLIProxyAPI routes Haiku only by its dated id; the undated alias reads as unknown.
    @Test func claudeSubscriptionIncludesLatestReleaseAndPreservesSavedModels() {
        #expect(BrainModelCatalog.models(for: .claudeSubscription).map(\.id) == [
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-haiku-4-5-20251001",
        ])
    }

    @Test func openAIAndCodexSubscriptionShareTheSameCatalog() {
        #expect(BrainModelCatalog.models(for: .openAI) == BrainModelCatalog.all)
        #expect(BrainModelCatalog.models(for: .codexSubscription) == BrainModelCatalog.all)
    }

    @Test func lookupFindsKnownModelsAndRejectsUnknown() {
        #expect(BrainModelCatalog.model(id: "gpt-5.6-terra")?.displayName == "GPT-5.6 Terra")
        #expect(BrainModelCatalog.model(id: "gpt-5.4-mini")?.displayName == "GPT-5.4 mini")
        #expect(BrainModelCatalog.model(id: "gpt-9000") == nil)
    }

    @Test func everyProviderUsesItsFirstCatalogEntryAsDefault() {
        for provider in BrainProvider.allCases {
            let models = BrainModelCatalog.models(for: provider)
            #expect(models.count == (provider == .claudeSubscription ? 5 : 7))
            #expect(Set(models.map(\.id)).count == models.count)
            #expect(models.allSatisfy { !$0.id.isEmpty })
            #expect(BrainModelCatalog.defaultModel(for: provider) == models.first)
        }
    }

    @Test func providerDefaultsFollowCatalogOrder() {
        #expect(BrainModelCatalog.defaultModel(for: .openAI).id == "gpt-5.6-sol")
        #expect(BrainModelCatalog.defaultModel(for: .codexSubscription).id == "gpt-5.6-sol")
        #expect(BrainModelCatalog.defaultModel(for: .claudeSubscription).id == "claude-opus-5")
    }

    @Test func perProviderLookupIsScopedToThatProvider() {
        #expect(
            BrainModelCatalog.model(id: "claude-opus-5", for: .claudeSubscription)?.displayName
                == "Claude Opus 5")
        #expect(BrainModelCatalog.model(id: "sonnet", for: .claudeSubscription) == nil)
        #expect(BrainModelCatalog.model(id: "", for: .codexSubscription) == nil)
        #expect(BrainModelCatalog.model(id: "gpt-5.5", for: .claudeSubscription) == nil)
    }

    @Test func summarizerModelsUseVerifiedProviderBehavior() {
        #expect(BrainModelCatalog.summarizerModelID(for: .openAI) == "gpt-5.4-mini")
        #expect(BrainModelCatalog.summarizerModelID(for: .claudeSubscription) == "claude-haiku-4-5-20251001")
        #expect(BrainModelCatalog.summarizerModelID(for: .codexSubscription) == "")
    }

    @Test func effortFloorsAreModelData() {
        let floored: Set<String> = ["gpt-6-astra"]
        for provider in BrainProvider.allCases {
            for model in BrainModelCatalog.models(for: provider) {
                #expect(model.reasoningEffortFloor == (floored.contains(model.id) ? .low : nil),
                        "\(provider.rawValue) \(model.id)")
            }
        }
    }
}
