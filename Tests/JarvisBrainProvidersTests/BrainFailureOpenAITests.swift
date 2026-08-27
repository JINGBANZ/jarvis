import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

/// The OpenAI HTTP classification feeding the ordered route policy: unknown and request-local
/// failures stay temporary (the three-failure budget), and only reviewed proof of an unrecoverable
/// target is permanent (immediate exhaustion).
@Suite struct BrainFailureOpenAITests {
    @Test func serverFailuresShareTemporaryPolicy() {
        for status in [408, 409, 500, 503, 599] {
            let failure = BrainFailure.openAIHTTP(
                status: status, errorCode: nil, errorType: nil, detail: "failed")
            #expect(failure.disposition == .temporary)
        }
    }

    @Test func rateLimitFailuresRemainTemporary() {
        let rateLimit = BrainFailure.openAIHTTP(
            status: 429, errorCode: "rate_limit_exceeded", errorType: nil, detail: "limited")
        #expect(rateLimit.disposition == .temporary)
    }

    @Test func unknownAndRequestLocalHTTPFailuresRemainTemporary() {
        for status in [400, 404, 418, 422, 423, 424, 425, 429] {
            let failure = BrainFailure.openAIHTTP(
                status: status, errorCode: "future_code", errorType: "future_type", detail: "failed")
            #expect(failure.disposition == .temporary)
        }
    }

    @Test func onlyProvenPermanentFailuresArePermanent() {
        for status in [401, 402, 403] {
            #expect(BrainFailure.openAIHTTP(
                status: status, errorCode: nil, errorType: nil, detail: "failed"
            ).disposition == .permanent)
        }
        for code in ["invalid_api_key", "insufficient_quota", "model_not_found"] {
            #expect(BrainFailure.openAIHTTP(
                status: 429, errorCode: code, errorType: nil, detail: "failed"
            ).disposition == .permanent)
        }
        #expect(BrainFailure.openAIHTTP(
            status: 429, errorCode: nil, errorType: "authentication_error", detail: "failed"
        ).disposition == .permanent)
    }
}
