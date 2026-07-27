import Testing
@testable import JarvisCore

@Suite struct BrainModelCatalogTests {
    @Test func catalogIsNonEmptyWithUniqueIDs() {
        let ids = BrainModelCatalog.all.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)   // no duplicate model ids
    }

    @Test func sharedOpenAIListContainsExactlySixModels() {
        #expect(BrainModelCatalog.all.map(\.id) == [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
        ])
    }

    @Test func claudeCodeListsOnlyTheNewestReleaseInEachFamily() {
        #expect(BrainModelCatalog.models(for: .claudeCode).map(\.id) == [
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-haiku-4-5",
        ])
    }

    @Test func openAIAndCodexCLIShareTheSameCatalog() {
        #expect(BrainModelCatalog.models(for: .openAI) == BrainModelCatalog.all)
        #expect(BrainModelCatalog.models(for: .codexCLI) == BrainModelCatalog.all)
    }

    @Test func lookupFindsKnownModelsAndRejectsUnknown() {
        #expect(BrainModelCatalog.model(id: "gpt-5.6-terra")?.displayName == "GPT-5.6 Terra")
        #expect(BrainModelCatalog.model(id: "gpt-5.4-mini")?.displayName == "GPT-5.4 mini")
        #expect(BrainModelCatalog.model(id: "gpt-9000") == nil)
    }

    @Test func everyProviderUsesItsFirstCatalogEntryAsDefault() {
        for provider in BrainProvider.allCases {
            let models = BrainModelCatalog.models(for: provider)
            #expect(models.count == (provider == .claudeCode ? 4 : 6))
            #expect(Set(models.map(\.id)).count == models.count)
            #expect(models.allSatisfy { !$0.id.isEmpty })
            #expect(BrainModelCatalog.defaultModel(for: provider) == models.first)
        }
    }

    @Test func providerDefaultsFollowCatalogOrder() {
        #expect(BrainModelCatalog.defaultModel(for: .openAI).id == "gpt-5.6-sol")
        #expect(BrainModelCatalog.defaultModel(for: .codexCLI).id == "gpt-5.6-sol")
        #expect(BrainModelCatalog.defaultModel(for: .claudeCode).id == "claude-opus-5")
    }

    @Test func perProviderLookupIsScopedToThatProvider() {
        #expect(
            BrainModelCatalog.model(id: "claude-opus-5", for: .claudeCode)?.displayName
                == "Claude Opus 5")
        #expect(BrainModelCatalog.model(id: "sonnet", for: .claudeCode) == nil)
        #expect(BrainModelCatalog.model(id: "", for: .codexCLI) == nil)
        #expect(BrainModelCatalog.model(id: "gpt-5.5", for: .claudeCode) == nil)
    }

    @Test func summarizerModelsUseVerifiedProviderBehavior() {
        #expect(BrainModelCatalog.summarizerModelID(for: .openAI) == "gpt-5.4-mini")
        #expect(BrainModelCatalog.summarizerModelID(for: .claudeCode) == "claude-haiku-4-5")
        #expect(BrainModelCatalog.summarizerModelID(for: .codexCLI) == "")
    }
}
