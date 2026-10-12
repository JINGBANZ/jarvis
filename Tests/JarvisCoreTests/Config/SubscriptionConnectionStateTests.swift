import JarvisCore
import Testing

@Suite struct SubscriptionConnectionStateTests {
    private func failure(
        _ provider: BrainProvider, category: ProviderFailure.Category = .unavailable,
        disposition: ProviderFailure.Disposition = .temporary
    ) -> ProviderFailure {
        ProviderFailure(source: .brain(provider), stage: .process, category: category,
                        disposition: disposition, identity: .init(), message: "The subscription is unavailable.")
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription],
          [ProviderFailure.Category.unavailable, .unreachable, .quota, .unknown, .timeout])
    func temporaryFailuresOfferRetryAndLocalSignOut(provider: BrainProvider, category: ProviderFailure.Category) {
        let state = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1, health: .unavailable(failure(provider, category: category)))

        #expect(state.buttons == [.init(.retry), .init(.signOut)])
        #expect(state.detail == "The subscription is unavailable.")
        #expect(!state.detail.contains("Settings"))
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription])
    func rejectedCredentialsOfferOnlySignIn(provider: BrainProvider) {
        let state = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1,
            health: .unavailable(failure(provider, category: .authentication, disposition: .permanent)))

        #expect(state.buttons == [.init(.signIn)])
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription])
    func disabledCredentialsAndMultipleAccountsOfferOnlySignOut(provider: BrainProvider) {
        let disabled = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1,
            health: .unavailable(failure(provider, category: .configuration, disposition: .permanent)))
        #expect(disabled.buttons == [.init(.signOut)])
        for health: BrainRouteAvailability.ConnectionHealth in [.checking, .ready, .unavailable(failure(provider))] {
            let multiple = SubscriptionConnectionState(provider: provider, savedAccountCount: 2, health: health)
            #expect(multiple.buttons == [.init(.signOut)])
            #expect(multiple.detail.contains("Multiple saved accounts"))
        }
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription])
    func noSavedAccountAlwaysOffersSignInEvenWithStaleOrUnavailableHealth(provider: BrainProvider) {
        for health: BrainRouteAvailability.ConnectionHealth in [.checking, .ready, .unavailable(failure(provider))] {
            let state = SubscriptionConnectionState(provider: provider, savedAccountCount: 0, health: health)
            #expect(state.buttons == [.init(.signIn)])
            #expect(!state.detail.hasPrefix("Signed in"))
        }
        let signedOut = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 0,
            health: .unavailable(failure(provider, category: .authentication, disposition: .permanent)))
        #expect(signedOut.tone == .neutral)
        #expect(signedOut.detail.hasPrefix("Signed out"))
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription])
    func passiveChecksAndHealthyAccountsKeepSignOutAvailable(provider: BrainProvider) {
        let checking = SubscriptionConnectionState(provider: provider, savedAccountCount: 1, health: .checking)
        #expect(checking.buttons == [.init(.signOut)])
        let ready = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1, accountDescription: "fixture@example.com · plus", health: .ready)
        #expect(ready.buttons == [.init(.signOut)])
        #expect(ready.detail == "Signed in · fixture@example.com · plus")
    }

    @Test(arguments: [BrainProvider.codexSubscription, .claudeSubscription])
    func operationsPreventConflictingActions(provider: BrainProvider) {
        let health = BrainRouteAvailability.ConnectionHealth.unavailable(failure(provider))
        let signingIn = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1, health: health, operation: .signingIn)
        #expect(signingIn.buttons == [.init(.cancelSignIn)])
        let signingOut = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1, health: health, operation: .signingOut)
        #expect(signingOut.buttons == [.init(.signOut, title: "Signing out…", isEnabled: false)])
        let retrying = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1, health: health, operation: .retrying)
        #expect(retrying.buttons == [.init(.retry, title: "Trying again…", isEnabled: false),
                                    .init(.signOut, isEnabled: false)])
        #expect(retrying.detail == "The subscription is unavailable.")
        let otherRetry = SubscriptionConnectionState(
            provider: provider, savedAccountCount: 1, health: health,
            retryAvailable: false, accountActionsAvailable: false)
        #expect(otherRetry.buttons == [.init(.retry, isEnabled: false), .init(.signOut, isEnabled: false)])
    }

    @Test func errorDetailsRetainIdentityAndRedactionWithoutActivityAdvice() {
        let failure = ProviderFailure(
            source: .brain(.claudeSubscription), stage: .process, category: .unavailable,
            disposition: .temporary, identity: .init(httpStatus: 503),
            message: "Authorization: Bearer secret-token-value")
        let state = SubscriptionConnectionState(
            provider: .claudeSubscription, savedAccountCount: 1, health: .unavailable(failure))
        #expect(state.detail.contains("HTTP 503"))
        #expect(!state.detail.contains("secret-token-value"))
        #expect(!state.detail.contains("Try again"))
        #expect(failure.activityAdvice.contains("Try again"))
    }
}
