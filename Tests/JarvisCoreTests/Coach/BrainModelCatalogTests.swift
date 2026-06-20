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

    @Test func lookupFindsKnownModelsAndRejectsUnknown() {
        #expect(BrainModelCatalog.model(id: "gpt-5.4-mini")?.displayName == "GPT-5.4 mini")
        #expect(BrainModelCatalog.model(id: "gpt-9000") == nil)
    }
}
