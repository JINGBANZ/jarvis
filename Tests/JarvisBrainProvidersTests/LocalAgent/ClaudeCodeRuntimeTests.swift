import Foundation
import Testing
@testable import JarvisBrainProviders
import JarvisCore

@Suite struct ClaudeCodeRuntimeTests {
    /// Restating a stalled turn against its real budget must not cost the classification: the route
    /// and Activity read the classified category, and a generic error code would demote a Claude
    /// timeout to an unclassified CLI fault.
    @Test func restatedTurnTimeoutStillClassifiesAsATimeout() {
        var trace = StreamTrace()
        trace.record(["type": "system", "subtype": "thinking_tokens"])
        let runtimeTimeout = NSError(
            domain: AgentRuntimeProcess.errorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "claude timed out after 0s: not logged in"])

        let restated = ClaudeCodeQuery.describingTurnFailure(
            runtimeTimeout,
            budget: 90,
            dispatchedAt: DispatchTime.now().uptimeNanoseconds,
            trace: trace)

        let failure = LocalAgentFailureClassifier.classify(error: restated, provider: .claudeCode)
        #expect(failure.category == .timeout)
        #expect(failure.disposition == .temporary)
        #expect(failure.message.contains("within 90s"))
        #expect(failure.message.contains("system/thinking_tokens×1"))
        // The stderr tail the process layer appended is the decisive evidence; it survives.
        #expect(failure.message.contains("not logged in"))
    }

    /// A deadline that expires between reads is raised by the query itself, in its own domain, and
    /// takes the same restatement path.
    @Test func deadlineExpiringBetweenReadsAlsoClassifiesAsATimeout() {
        let deadlineExpired = NSError(
            domain: LocalAgentFailureClassifier.claudeCodeDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Claude response timed out"])

        let restated = ClaudeCodeQuery.describingTurnFailure(
            deadlineExpired,
            budget: 45,
            dispatchedAt: DispatchTime.now().uptimeNanoseconds,
            trace: StreamTrace())

        let failure = LocalAgentFailureClassifier.classify(error: restated, provider: .claudeCode)
        #expect(failure.category == .timeout)
        #expect(failure.message.contains("within 45s"))
        #expect(failure.message.contains("no stream events"))
    }

    /// Anything that is not a timeout is handed back untouched, so its own classification stands.
    @Test func nonTimeoutFailuresAreNotRestated() {
        let rejected = NSError(
            domain: LocalAgentFailureClassifier.claudeCodeDomain, code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Claude requested unexpected control input"])

        let passedThrough = ClaudeCodeQuery.describingTurnFailure(
            rejected,
            budget: 90,
            dispatchedAt: DispatchTime.now().uptimeNanoseconds,
            trace: StreamTrace())

        #expect((passedThrough as NSError) == rejected)
        let failure = LocalAgentFailureClassifier.classify(
            error: passedThrough, provider: .claudeCode)
        #expect(failure.category == .unknown)
        #expect(failure.disposition == .temporary)
    }
}
