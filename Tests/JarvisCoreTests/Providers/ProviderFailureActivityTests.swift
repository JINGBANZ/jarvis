import Testing
@testable import JarvisCore

@Suite struct ProviderFailureActivityTests {
    private func make(
        source: ProviderFailure.Source = .transcription(.openAI),
        category: ProviderFailure.Category,
        identity: ProviderFailure.Identity = .init(),
        message: String = ""
    ) -> ProviderFailure {
        ProviderFailure(source: source, stage: .session, category: category,
                        disposition: .temporary, identity: identity, message: message)
    }

    @Test func quotesIdentityAndMessageInsideTheFixedSentence() {
        let failure = make(
            category: .access,
            identity: .init(httpStatus: 403, errorCode: "unsupported_country_region_territory"),
            message: "Country, region, or territory not supported")
        #expect(failure.activitySentence
                == "OpenAI denied access (HTTP 403, unsupported_country_region_territory: Country, region, or territory not supported); check your region, VPN, or API project")
    }

    @Test func omitsEmptyPartsWithoutLeavingPunctuationBehind() {
        #expect(make(category: .disconnected, identity: .init(closeCode: 1006)).activitySentence
                == "the transcription connection to OpenAI was lost (close 1006)")
        #expect(make(category: .rejected, message: "Rate limit reached").activitySentence
                == "OpenAI refused the transcription request (Rate limit reached)")
        #expect(make(category: .unknown).activitySentence == "OpenAI failed")
    }

    @Test func unreachableAndTimeoutNameTheSurface() {
        #expect(make(category: .unreachable, identity: .init(transportDomain: "NSURLErrorDomain", transportCode: -1004),
                     message: "could not connect to the server").activitySentence
                == "OpenAI couldn't be reached for transcription (network -1004: could not connect to the server); check your network or VPN")
        #expect(make(source: .brain(.openAI), category: .timeout).activitySentence
                == "OpenAI API didn't respond in time")
    }

    @Test func anAPIKeyProviderIsToldToCheckItsKey() {
        #expect(make(source: .brain(.openAI), category: .authentication).activitySentence
                == "OpenAI API rejected the API key; check Settings → Connections")
    }

    /// A subscription's sign-in, its helper, and its plan limit each say what to do in Jarvis.
    @Test func subscriptionsNameTheirOwnNextStep() {
        let signIn = "open Settings → Connections, press Sign in for it, then press Start"
        #expect(make(source: .brain(.claudeSubscription), category: .authentication).activitySentence
                == "Claude subscription isn't signed in; \(signIn)")
        // The helper's reply for a signed-out vendor and for a model it does not serve alike.
        #expect(make(source: .brain(.claudeSubscription), category: .configuration,
                     identity: .init(httpStatus: 400, errorCode: "model_not_found"),
                     message: "unknown provider for model claude-opus-5").activitySentence
                == "Claude subscription rejected the coaching configuration (HTTP 400, model_not_found: unknown provider for model claude-opus-5); check Settings → Brain")
        #expect(make(source: .brain(.codexSubscription), category: .unreachable,
                     identity: .init(transportDomain: "NSURLErrorDomain", transportCode: -1004),
                     message: "could not connect to the server").activitySentence
                == "Codex subscription couldn't reach the sign-in service (network -1004: could not connect to the server); quit and reopen Jarvis")
        let stopped = ProviderFailure(
            source: .brain(.claudeSubscription), stage: .process, category: .unavailable,
            disposition: .permanent, identity: .init(), message: "the sign-in service keeps stopping")
        #expect(stopped.activitySentence
                == "Claude subscription is unavailable (the sign-in service keeps stopping); quit and reopen Jarvis")
        #expect(make(source: .brain(.codexSubscription), category: .rejected,
                     identity: .init(httpStatus: 429),
                     message: "All credentials for model gpt-5.6-sol are cooling down").activitySentence
                == "Codex subscription reached its usage limit (HTTP 429: All credentials for model gpt-5.6-sol are cooling down); wait for the limit to reset, or add a fallback in Settings → Brain")
        // An upstream outage behind the helper reads as any provider's does.
        #expect(make(source: .brain(.claudeSubscription), category: .unavailable,
                     identity: .init(httpStatus: 503)).activitySentence
                == "Claude subscription is unavailable (HTTP 503)")
    }

    /// The four clauses no exact-string test pinned. A clause is copy: it changes only on purpose.
    @Test func theRemainingClausesReadAsWritten() {
        #expect(make(source: .brain(.openAI), category: .quota).activitySentence
                == "OpenAI API reported an exhausted quota; check billing")
        #expect(make(source: .brain(.openAI), category: .configuration).activitySentence
                == "OpenAI API rejected the coaching configuration; check Settings \u{2192} Brain")
        #expect(make(category: .unavailable, identity: .init(httpStatus: 503)).activitySentence
                == "OpenAI is unavailable (HTTP 503)")
        #expect(make(source: .brain(.openAI), category: .response).activitySentence
                == "OpenAI API couldn't finish the response")
    }

    /// A frame that says what Jarvis is doing puts the advice last, so the row does not read as two
    /// instructions on either side of the frame's dash.
    @Test func adviceCanBeMovedBehindAFrame() {
        let failure = make(
            category: .unreachable,
            identity: .init(transportDomain: "NSURLErrorDomain", transportCode: -1009),
            message: "the internet connection appears to be offline")
        #expect(failure.activitySentenceWithoutAdvice
                == "OpenAI couldn't be reached for transcription (network -1009: the internet connection appears to be offline)")
        #expect(failure.activityAdvice == "; check your network or VPN")
        #expect(failure.activitySentenceWithoutAdvice + failure.activityAdvice
                == failure.activitySentence)
        #expect(make(category: .unknown).activityAdvice == "")
    }

    @Test func captureUsesItsOwnNoun() {
        #expect(make(source: .capture, category: .unavailable, message: "no input device").activitySentence
                == "audio capture became unavailable (no input device)")
    }

    /// The message is already redacted by the record, so a token can never reach a row.
    @Test func sentenceNeverCarriesASecret() {
        let failure = make(category: .authentication, message: "Authorization: Bearer secret-token-value")
        #expect(!failure.activitySentence.contains("secret-token-value"))
    }

    @Test func everyCategoryRendersASentence() {
        for category in ProviderFailure.Category.allCases {
            #expect(!make(category: category).activitySentence.isEmpty)
            #expect(!make(category: category).activitySentence.contains("—"))
        }
    }

    /// The parenthetical on its own, for frames that place their own verb around it.
    @Test func activityDetailIsTheParentheticalOrNothing() {
        #expect(make(category: .rejected, identity: .init(httpStatus: 429, errorCode: "rate_limit_exceeded"),
                     message: "Rate limit reached").activityDetail
                == " (HTTP 429, rate_limit_exceeded: Rate limit reached)")
        #expect(make(category: .rejected, identity: .init(httpStatus: 503)).activityDetail == " (HTTP 503)")
        #expect(make(category: .rejected, message: "slow").activityDetail == " (slow)")
        #expect(make(category: .unknown).activityDetail == "")
    }
}
