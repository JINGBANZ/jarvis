import Foundation
import Testing
@testable import JarvisCore

@Suite struct BrainFailureTests {
    @Test func unknownFutureErrorDefaultsToTemporaryWithoutImmediateRetry() {
        let failure = BrainFailure(NSError(
            domain: "FutureProvider", code: 999,
            userInfo: [NSLocalizedDescriptionKey: "new failure"]))

        #expect(failure.disposition == .temporary)
        #expect(!failure.retriesImmediately)
        #expect(failure.detail == "new failure")
    }

    @Test func retryableTransportAndServerFailuresShareTemporaryPolicy() {
        for error in [URLError(.timedOut), URLError(.networkConnectionLost)] {
            let failure = BrainFailure(error)
            #expect(failure.disposition == .temporary)
            #expect(failure.retriesImmediately)
        }
        for status in [408, 409, 500, 503, 599] {
            let failure = BrainFailure.openAIHTTP(
                status: status, errorCode: nil, errorType: nil, detail: "failed")
            #expect(failure.disposition == .temporary)
            #expect(failure.retriesImmediately)
        }
    }

    @Test func temporaryFailuresCanDeclineImmediateRetry() {
        let errors: [Error] = [
            NSError(domain: AgentCLIProcessRunner.errorDomain, code: NSURLErrorTimedOut),
            NSError(domain: "CLIBrainClient", code: 1),
        ]

        for error in errors {
            let failure = BrainFailure(error)
            #expect(failure.disposition == .temporary)
            #expect(!failure.retriesImmediately)
        }
        let rateLimit = BrainFailure.openAIHTTP(
            status: 429, errorCode: "rate_limit_exceeded", errorType: nil, detail: "limited")
        #expect(rateLimit.disposition == .temporary)
        #expect(!rateLimit.retriesImmediately)
    }

    @Test func unknownAndRequestLocalHTTPFailuresRemainTemporary() {
        for status in [400, 418, 422, 423, 424, 425, 429] {
            let failure = BrainFailure.openAIHTTP(
                status: status, errorCode: "future_code", errorType: "future_type", detail: "failed")
            #expect(failure.disposition == .temporary)
            #expect(!failure.retriesImmediately)
        }
    }

    @Test func onlyProvenOrExplicitPermanentFailuresAreTerminal() {
        for status in [401, 402, 403, 404] {
            #expect(BrainFailure.openAIHTTP(
                status: status, errorCode: nil, errorType: nil, detail: "failed"
            ).disposition == .terminal)
        }
        for code in ["invalid_api_key", "insufficient_quota", "model_not_found"] {
            #expect(BrainFailure.openAIHTTP(
                status: 429, errorCode: code, errorType: nil, detail: "failed"
            ).disposition == .terminal)
        }
        #expect(BrainFailure.openAIHTTP(
            status: 429, errorCode: nil, errorType: "authentication_error", detail: "failed"
        ).disposition == .terminal)
        let explicit = BrainFailure(
            disposition: .terminal, detail: "provider proved authentication is invalid")
        #expect(BrainFailure(explicit) == explicit)
    }
}
