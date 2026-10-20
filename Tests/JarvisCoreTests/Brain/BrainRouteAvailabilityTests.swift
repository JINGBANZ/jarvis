import Testing
@testable import JarvisCore

@Suite struct BrainRouteAvailabilityTests {
    private let codex = BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol")
    private let claude = BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5-5")
    private let gemini = BrainTarget(provider: .gemini, modelID: "gemini-3.8-flash")
    private let openAI = BrainTarget(provider: .openAI, modelID: "gpt-6.1-sol")

    private func failure(_ provider: BrainProvider) -> ProviderFailure {
        ProviderFailure(
            source: .brain(provider), stage: .process, category: .authentication,
            disposition: .permanent, identity: .init(errorCode: "refresh_token_invalidated"),
            message: "Sign in again.")
    }

    @Test func aUsablePrimaryDoesNotWaitForUnusedFallbacks() {
        let availability = BrainRouteAvailability(
            route: BrainRoute(primary: codex, fallbackTargets: [openAI, claude]),
            availableCredentials: [], subscriptions: [codex: .ready])

        #expect(availability.state == .ready(codex, primaryFailure: nil))
        #expect(availability.blockingFailure == nil)
        #expect(availability.failure(for: openAI)?.category == .missingCredential)
        #expect(availability.health(for: claude) == .checking)
    }

    @Test func anEarlierUncheckedFallbackMustAnswerBeforeSelectingALaterOne() {
        let primaryFailure = failure(.codexSubscription)
        let route = BrainRoute(primary: codex, fallbackTargets: [claude, gemini])
        let checking = BrainRouteAvailability(
            route: route, availableCredentials: [.geminiAPIKey],
            subscriptions: [codex: .unavailable(primaryFailure)])

        #expect(checking.state == .checking)
        #expect(checking.blockingFailure == primaryFailure)
        #expect(checking.failure(for: claude)?.disposition == .temporary)

        let answered = BrainRouteAvailability(
            route: route, availableCredentials: [.geminiAPIKey], subscriptions: [
                codex: .unavailable(primaryFailure),
                claude: .unavailable(failure(.claudeSubscription)),
            ])
        #expect(answered.state == .ready(gemini, primaryFailure: primaryFailure))
        #expect(answered.blockingFailure == nil)
    }

    @Test func aSavedKeyOutsideTheRouteCannotMakeItUsable() {
        let primaryFailure = failure(.codexSubscription)
        let availability = BrainRouteAvailability(
            route: BrainRoute(primary: codex, fallbackTargets: [gemini]),
            availableCredentials: [.openAIAPIKey],
            subscriptions: [codex: .unavailable(primaryFailure)])

        #expect(availability.state == .unavailable(primaryFailure))
        #expect(availability.blockingFailure == primaryFailure)
        #expect(availability.failure(for: gemini)?.category == .missingCredential)
    }

    @Test func anUncheckedPrimaryIsNotReadyEvenWithASavedFallbackKey() {
        let availability = BrainRouteAvailability(
            route: BrainRoute(primary: codex, fallbackTargets: [gemini]),
            availableCredentials: [.geminiAPIKey], subscriptions: [:])

        #expect(availability.state == .checking)
        #expect(availability.blockingFailure?.disposition == .temporary)
        #expect(availability.blockingFailure?.source == .brain(.codexSubscription))
    }
}
