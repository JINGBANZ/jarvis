import Foundation
import Testing
@testable import JarvisCore
import JarvisBrainProviders

/// The provider-neutral classification contract: everything a provider adapter has not proven
/// anything about wraps as a recoverable `.temporary` missed turn. Each adapter's own permanence
/// proof is tested beside that adapter (see `BrainFailureOpenAITests` in
/// `JarvisBrainProvidersTests`).
@Suite struct BrainFailureTests {
    @Test func unknownFutureErrorDefaultsToTemporary() {
        let failure = BrainFailure(NSError(
            domain: "FutureProvider", code: 999,
            userInfo: [NSLocalizedDescriptionKey: "new failure"]))

        #expect(failure.disposition == .temporary)
        #expect(failure.detail == "new failure")
    }

    @Test func transportFailuresShareTemporaryPolicy() {
        for error in [URLError(.timedOut), URLError(.networkConnectionLost)] {
            let failure = BrainFailure(error)
            #expect(failure.disposition == .temporary)
        }
    }

    @Test func cliFailuresRemainTemporary() {
        let errors: [Error] = [
            NSError(domain: AgentCLIProcessRunner.errorDomain, code: NSURLErrorTimedOut),
            NSError(domain: "CLIBrainClient", code: 1),
        ]

        for error in errors {
            let failure = BrainFailure(error)
            #expect(failure.disposition == .temporary)
        }
    }

    @Test func explicitPermanentFailureSurvivesRewrapping() {
        let explicit = BrainFailure(
            disposition: .permanent, detail: "provider proved authentication is invalid")
        #expect(BrainFailure(explicit) == explicit)
    }
}
