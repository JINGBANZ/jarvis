import Foundation
import Testing
@testable import JarvisCore

@Suite struct LocalAgentFailureClassifierTests {
    /// The runtime's stdout-overflow error is an errno, not an exit status. Under the runtime's own
    /// domain a non-negative code means an exit status, so this used to tell a person the CLI had
    /// exited 84 when it had not exited at all.
    @Test func aRuntimeErrnoReadsAsAnErrnoRatherThanAnExitStatus() {
        let failure = LocalAgentFailureClassifier.classify(
            error: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW),
                userInfo: [NSLocalizedDescriptionKey: "local agent runtime stdout exceeded its buffer limit"]),
            provider: .codexCLI)
        #expect(failure.category == .unavailable)
        #expect(failure.disposition == .temporary)
        #expect(failure.identity.summary == "errno 84")
        #expect(failure.identity.exitStatus == nil)
    }

    /// The runtime encodes the exit status as the NSError code and appends the stderr tail to the
    /// description; both survive, the tail redacted and capped.
    @Test func runtimeExitKeepsStatusAndStderrTail() {
        let error = NSError(domain: LocalAgentFailureClassifier.runtimeProcessDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "local agent runtime stopped (exit 1); stderr: Not logged in. Run /login. token=abc",
        ])
        let failure = LocalAgentFailureClassifier.classify(error: error, provider: .claudeCode)
        #expect(failure.source == .brain(.claudeCode))
        #expect(failure.stage == .process)
        #expect(failure.category == .unknown)
        #expect(failure.disposition == .temporary)
        #expect(failure.identity.exitStatus == 1)
        #expect(failure.message.contains("Not logged in"))
    }

    @Test func timeoutsAreTimeoutsWhicheverAdapterRaisedThem() {
        for domain in [LocalAgentFailureClassifier.runtimeProcessDomain, LocalAgentFailureClassifier.processRunnerDomain,
                       LocalAgentFailureClassifier.clientDomain, LocalAgentFailureClassifier.claudeCodeDomain] {
            let error = NSError(domain: domain, code: NSURLErrorTimedOut,
                                userInfo: [NSLocalizedDescriptionKey: "timed out after 60s"])
            let failure = LocalAgentFailureClassifier.classify(error: error, provider: .codexCLI)
            #expect(failure.category == .timeout)
            #expect(failure.disposition == .temporary)
            #expect(failure.identity.exitStatus == nil)
            #expect(failure.identity.transportDomain == domain)
        }
    }

    @Test func spawnFailuresAreUnavailable() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                            userInfo: [NSLocalizedDescriptionKey: "No such file or directory"])
        let failure = LocalAgentFailureClassifier.classify(error: error, provider: .claudeCode)
        #expect(failure.category == .unavailable)
        #expect(failure.identity.transportCode == Int(ENOENT))
    }

    @Test func alreadyClassifiedFailuresPassThrough() {
        let permanent = ProviderFailure(source: .brain(.claudeCode), stage: .process, category: .authentication,
                                        disposition: .permanent, identity: .init(), message: "signed out")
        #expect(LocalAgentFailureClassifier.classify(error: permanent, provider: .claudeCode) == permanent)
    }
}
