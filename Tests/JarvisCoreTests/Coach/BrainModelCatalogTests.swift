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

@Suite struct ReasoningEffortTests {
    @Test func hasExactlyTheFourSupportedLevelsInOrder() {
        #expect(ReasoningEffort.allCases == [.none, .low, .medium, .high])
    }

    @Test func rawValuesAreTheAPIStrings() {
        #expect(ReasoningEffort.none.rawValue == "none")
        #expect(ReasoningEffort.low.rawValue == "low")
        #expect(ReasoningEffort.medium.rawValue == "medium")
        #expect(ReasoningEffort.high.rawValue == "high")
    }

    @Test func defaultIsLow() {
        #expect(ReasoningEffort.default == .low)
    }
}
