import Foundation
import Testing
@testable import JarvisCore

@Suite struct AnthropicFailureClassifierTests {
    private let brain = ProviderFailure.Source.brain(.claudeSubscription)

    private func body(type: String, message: String = "m") -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])
    }

    private func classify(_ status: Int, _ body: Data?, stage: ProviderFailure.Stage = .request) -> ProviderFailure {
        AnthropicFailureClassifier.classify(httpStatus: status, body: body, source: brain, stage: stage)
    }

    @Test func errorTypesFollowTheTable() {
        let auth = classify(401, body(type: "authentication_error"))
        #expect(auth.category == .authentication && auth.disposition == .permanent)
        #expect(auth.identity == .init(httpStatus: 401, errorType: "authentication_error"))
        let denied = classify(403, body(type: "permission_error"))
        #expect(denied.category == .access && denied.disposition == .permanent)
        let billing = classify(402, body(type: "billing_error"))
        #expect(billing.category == .quota && billing.disposition == .permanent)
        let missing = classify(404, body(type: "not_found_error", message: "model: claude-nope"))
        #expect(missing.category == .configuration && missing.disposition == .permanent)
        let limited = classify(429, body(type: "rate_limit_error"))
        #expect(limited.category == .rejected && limited.disposition == .temporary)
        let overloaded = classify(529, body(type: "overloaded_error"))
        #expect(overloaded.category == .unavailable && overloaded.disposition == .temporary)
        let down = classify(500, body(type: "api_error"))
        #expect(down.category == .unavailable && down.disposition == .temporary)
        // A code outranks its status, as on the other vendors.
        let authOn429 = classify(429, body(type: "authentication_error"))
        #expect(authOn429.category == .authentication && authOn429.disposition == .permanent)
    }

    /// The helper answers its Messages route in Anthropic's shape, for its own errors too.
    @Test func theHelpersUnknownModelIsAConfigurationFailure() {
        let failure = classify(400, body(type: "invalid_request_error", message: "unknown provider for model claude-opus-5"))
        #expect(failure.category == .configuration && failure.disposition == .permanent)
        #expect(failure.identity == .init(httpStatus: 400, errorType: "invalid_request_error"))
        #expect(failure.activitySentence == "Claude Code rejected the coaching configuration "
            + "(HTTP 400, invalid_request_error: unknown provider for model claude-opus-5); "
            + "check Settings → Brain, or sign in again in Settings → Connections")
    }

    @Test func aRateLimitReadsAsThePlansUsageLimit() {
        let failure = classify(429, body(type: "rate_limit_error", message: "Slow down."))
        #expect(failure.activitySentence == "Claude Code reached its usage limit (HTTP 429, rate_limit_error: Slow down.); "
            + "wait for the limit to reset, or add a fallback in Settings → Brain")
    }

    @Test func statusesAloneFollowTheBrainTable() {
        #expect(classify(401, nil).category == .authentication)
        #expect(classify(402, nil).category == .quota)
        #expect(classify(403, nil).category == .access)
        #expect(classify(404, nil).category == .configuration)
        let limited = classify(429, nil)
        #expect(limited.category == .rejected && limited.disposition == .temporary)
        for status in [400, 418, 422] {
            let failure = classify(status, nil)
            #expect(failure.category == .rejected && failure.disposition == .temporary)
        }
        for status in [500, 503, 529] {
            let failure = classify(status, nil)
            #expect(failure.category == .unavailable && failure.disposition == .temporary)
        }
        #expect(classify(400, nil, stage: .handshake).disposition == .permanent)
        #expect(classify(408, nil, stage: .handshake).disposition == .temporary)
    }

    @Test func quotesABodyThatIsNotAnthropicErrorJSON() {
        let failure = classify(502, Data("upstream connect error".utf8))
        #expect(failure.message == "upstream connect error")
        #expect(failure.identity == .init(httpStatus: 502))
        #expect(failure.category == .unavailable)
    }

    @Test func anUnknownTypeStaysTemporary() {
        let failure = classify(400, body(type: "future_error", message: "m"))
        #expect(failure.category == .rejected && failure.disposition == .temporary)
        #expect(failure.identity.errorType == "future_error")
    }
}
