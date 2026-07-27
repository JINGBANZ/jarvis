import Testing
@testable import JarvisCore

@Suite struct BrainModelCatalogTests {
    @Test func catalogIsNonEmptyWithUniqueIDs() {
        let ids = BrainModelCatalog.all.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)   // no duplicate model ids
    }

    @Test func defaultModelIsInCatalogAndIsGPT55() {
        #expect(BrainModelCatalog.all.contains(BrainModelCatalog.default))
        #expect(BrainModelCatalog.default.id == "gpt-5.5")
    }

    @Test func openAIListsSixNewestModelsFirst() {
        #expect(BrainModelCatalog.all.prefix(6).map(\.id) == [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4-mini",
            "gpt-5.4-nano",
        ])
    }

    @Test func claudeCodeListsSixNewestGenerallyAvailableReleasesFirst() {
        #expect(BrainModelCatalog.models(for: .claudeCode).prefix(6).map(\.id) == [
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-sonnet-4-6",
        ])
    }

    @Test func lookupFindsKnownModelsAndRejectsUnknown() {
        #expect(BrainModelCatalog.model(id: "gpt-5.6-terra")?.displayName == "GPT-5.6 Terra")
        #expect(BrainModelCatalog.model(id: "gpt-5.4-mini")?.displayName == "GPT-5.4 mini")
        #expect(BrainModelCatalog.model(id: "gpt-9000") == nil)
    }

    @Test func everyProviderHasModelsAndAContainedDefault() {
        for provider in BrainProvider.allCases {
            let models = BrainModelCatalog.models(for: provider)
            #expect(!models.isEmpty)
            #expect(Set(models.map(\.id)).count == models.count)
            #expect(models.contains(BrainModelCatalog.defaultModel(for: provider)))
        }
    }

    @Test func openAIProviderListMatchesLegacyCatalog() {
        #expect(BrainModelCatalog.models(for: .openAI) == BrainModelCatalog.all)
        #expect(BrainModelCatalog.defaultModel(for: .openAI) == BrainModelCatalog.default)
    }

    @Test func perProviderLookupIsScopedToThatProvider() {
        #expect(
            BrainModelCatalog.model(id: "claude-opus-5", for: .claudeCode)?.displayName
                == "Claude Opus 5")
        #expect(BrainModelCatalog.model(id: "sonnet", for: .claudeCode) != nil)
        #expect(BrainModelCatalog.model(id: "sonnet", for: .openAI) == nil)
        #expect(BrainModelCatalog.model(id: "gpt-5.5", for: .claudeCode) == nil)
    }

    @Test func summarizerModelIsCheaperTierOrCLIDefault() {
        #expect(BrainModelCatalog.summarizerModelID(for: .openAI) == "gpt-5.4-mini")
        #expect(BrainModelCatalog.summarizerModelID(for: .claudeCode) == "haiku")
        #expect(BrainModelCatalog.summarizerModelID(for: .codexCLI).isEmpty)
    }
}
