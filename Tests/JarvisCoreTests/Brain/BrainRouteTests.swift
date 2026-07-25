import Testing
@testable import JarvisCore

@Suite struct BrainRouteTests {
    @Test func preservesOrderedSameProviderDifferentModelTargets() {
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbacks = [
            BrainTarget(provider: .claudeCode, modelID: "opus"),
            BrainTarget(provider: .claudeCode, modelID: "haiku"),
            BrainTarget(provider: .codexCLI, modelID: ""),
        ]

        let route = BrainRoute(primary: primary, fallbackTargets: fallbacks)

        #expect(route.primary == primary)
        #expect(route.fallbackTargets == fallbacks)
        #expect(route.targets == [primary] + fallbacks)
    }

    @Test func removesUnknownAndExactDuplicateFallbackTargets() {
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let valid = BrainTarget(provider: .claudeCode, modelID: "opus")

        let route = BrainRoute(primary: primary, fallbackTargets: [
            primary,
            BrainTarget(provider: .claudeCode, modelID: "retired-model"),
            valid,
            valid,
            BrainTarget(provider: .openAI, modelID: "gpt-5.4"),
        ])

        #expect(route.fallbackTargets == [
            valid,
            BrainTarget(provider: .openAI, modelID: "gpt-5.4"),
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
