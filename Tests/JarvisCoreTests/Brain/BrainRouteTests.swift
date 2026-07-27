import Testing
@testable import JarvisCore

@Suite struct BrainRouteTests {
    @Test func preservesOrderedSameProviderDifferentModelTargets() {
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbacks = [
            BrainTarget(provider: .claudeCode, modelID: "claude-opus-5"),
            BrainTarget(provider: .claudeCode, modelID: "claude-haiku-4-5"),
            BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-sol"),
        ]

        let route = BrainRoute(primary: primary, fallbackTargets: fallbacks)

        #expect(route.primary == primary)
        #expect(route.fallbackTargets == fallbacks)
        #expect(route.targets == [primary] + fallbacks)
    }

    @Test func removesUnknownAndExactDuplicateFallbackTargets() {
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let valid = BrainTarget(provider: .claudeCode, modelID: "claude-opus-5")

        let route = BrainRoute(primary: primary, fallbackTargets: [
            primary,
            BrainTarget(provider: .claudeCode, modelID: "retired-model"),
            valid,
            valid,
            BrainTarget(provider: .openAI, modelID: "gpt-5.4-mini"),
        ])

        #expect(route.fallbackTargets == [
            valid,
            BrainTarget(provider: .openAI, modelID: "gpt-5.4-mini"),
        ])
    }

    @Test func unknownPrimaryModelUsesThatProvidersDefault() {
        let route = BrainRoute(
            primary: BrainTarget(provider: .claudeCode, modelID: "retired-model"),
            fallbackTargets: [])

        #expect(route.primary == BrainTarget(
            provider: .claudeCode,
            modelID: BrainModelCatalog.defaultModel(for: .claudeCode).id))
    }
}
