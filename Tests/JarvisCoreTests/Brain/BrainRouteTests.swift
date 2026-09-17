import Testing
@testable import JarvisCore

@Suite struct BrainRouteTests {
    @Test func preservesOrderedSameProviderDifferentModelTargets() {
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbacks = [
            BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"),
            BrainTarget(provider: .claudeSubscription, modelID: "claude-haiku-4-5-20251001"),
            BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-sol"),
        ]

        let route = BrainRoute(primary: primary, fallbackTargets: fallbacks)

        #expect(route.primary == primary)
        #expect(route.fallbackTargets == fallbacks)
        #expect(route.targets == [primary] + fallbacks)
    }

    @Test func removesUnknownAndExactDuplicateFallbackTargets() {
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let valid = BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5")

        let route = BrainRoute(primary: primary, fallbackTargets: [
            primary,
            BrainTarget(provider: .claudeSubscription, modelID: "retired-model"),
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
            primary: BrainTarget(provider: .claudeSubscription, modelID: "retired-model"),
            fallbackTargets: [])

        #expect(route.primary == BrainTarget(
            provider: .claudeSubscription,
            modelID: BrainModelCatalog.defaultModel(for: .claudeSubscription).id))
    }

    @Test func movingThePrimaryDownPromotesTheFirstFallback() {
        let primary = BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5")
        let first = BrainTarget(provider: .openAI, modelID: "gpt-5.6-sol")
        let second = BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5")
        let route = BrainRoute(primary: primary, fallbackTargets: [first, second])

        let moved = route.movingTarget(at: 0, by: 1)

        #expect(moved?.primary == first)
        #expect(moved?.fallbackTargets == [primary, second])
    }

    @Test func movingTheFirstFallbackUpMakesItThePrimary() {
        let primary = BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5")
        let first = BrainTarget(provider: .openAI, modelID: "gpt-5.6-sol")
        let route = BrainRoute(primary: primary, fallbackTargets: [first])

        let moved = route.movingTarget(at: 1, by: -1)

        #expect(moved?.primary == first)
        #expect(moved?.fallbackTargets == [primary])
    }

    @Test func movingPastEitherEndIsRefused() {
        let route = BrainRoute(
            primary: BrainTarget(provider: .openAI, modelID: "gpt-5.5"),
            fallbackTargets: [BrainTarget(provider: .openAI, modelID: "gpt-5.4-mini")])

        #expect(route.movingTarget(at: 0, by: -1) == nil)
        #expect(route.movingTarget(at: 1, by: 1) == nil)
        #expect(route.movingTarget(at: 5, by: -1) == nil)
        #expect(route.movingTarget(at: 1, by: .max) == nil)
    }

    @Test func requiredCredentialsNameEachKeyOnceAndNoneForSubscriptions() {
        let mixed = BrainRoute(
            primary: BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"),
            fallbackTargets: [
                BrainTarget(provider: .openAI, modelID: "gpt-5.5"),
                BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"),
                BrainTarget(provider: .openAI, modelID: "gpt-5.4"),
            ])
        #expect(mixed.requiredCredentials == [.openAIAPIKey])
        let subscriptionsOnly = BrainRoute(
            primary: BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"),
            fallbackTargets: [BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5")])
        #expect(subscriptionsOnly.requiredCredentials.isEmpty)
    }
}
