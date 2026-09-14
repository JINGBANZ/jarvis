import Foundation
import Testing
@testable import JarvisCore

@Suite struct SocketLifecyclePolicyTests {
    private let source = ProviderFailure.Source.transcription(.openAI)

    private func policy() -> SocketLifecyclePolicy {
        SocketLifecyclePolicy(
            source: .transcription(.openAI),
            firstConnect: RetrySchedule(maximumRetries: 2, initialDelay: 1, maximumDelay: 30),
            reconnect: RetrySchedule(maximumRetries: 6, initialDelay: 1, maximumDelay: 30))
    }

    private func transportCause() -> ProviderFailure {
        TransportFailureClassifier.classify(
            error: URLError(.cannotConnectToHost), source: source, everReady: false)
    }

    /// The bug this branch exists for: seven attempts of silence before a row that named nothing.
    /// A socket that was never acknowledged gets three attempts, then the session ends with the cause.
    @Test func aSocketThatIsNeverReadyGivesUpAfterThreeAttempts() {
        var policy = policy()
        #expect(policy.start() == .open(attempt: 1))
        #expect(policy.failed(transportCause()) == .retry(after: 1, attempt: 1))
        #expect(policy.retryElapsed() == .open(attempt: 2))
        #expect(policy.failed(transportCause()) == .retry(after: 2, attempt: 2))
        #expect(policy.retryElapsed() == .open(attempt: 3))

        guard case .terminate(let exhausted) = policy.failed(transportCause()) else {
            Issue.record("expected termination"); return
        }
        #expect(exhausted.category == .unreachable)
        #expect(exhausted.endsEverySession)
        #expect(exhausted.identity.transportCode == URLError.cannotConnectToHost.rawValue)
        #expect(exhausted.message == "could not connect to the server")
        #expect(policy.phase == .terminal)
    }

    /// Once a socket has worked, there is buffered audio worth replaying, so the budget is the long
    /// one and running it out degrades that stream rather than ending the session.
    @Test func aReadySocketKeepsTheLongBudgetAndStaysStreamLocal() {
        var policy = policy()
        _ = policy.start()
        #expect(policy.acknowledged() == .ready(replacement: false))

        for retry in 1...6 {
            guard case .retry(_, let attempt) = policy.failed(transportCause()) else {
                Issue.record("expected retry \(retry)"); return
            }
            #expect(attempt == retry)
            #expect(policy.retryElapsed() == .open(attempt: retry + 1))
        }
        guard case .terminate(let exhausted) = policy.failed(transportCause()) else {
            Issue.record("expected termination"); return
        }
        #expect(exhausted.category == .disconnected)
        #expect(!exhausted.endsEverySession)
    }

    /// A rejected key, a denied region, or a retired model is not something a retry fixes, so the
    /// budget is skipped entirely and the cause is reported as the provider stated it.
    @Test func aPermanentCauseTerminatesImmediatelyFromAnyLivePhase() {
        let rejected = ProviderFailure(
            source: source, stage: .close, category: .authentication, disposition: .permanent,
            identity: .init(closeCode: 3000, errorCode: "invalid_api_key"),
            message: "Incorrect API key provided")

        var connecting = policy()
        _ = connecting.start()
        #expect(connecting.failed(rejected) == .terminate(rejected))

        var ready = policy()
        _ = ready.start()
        _ = ready.acknowledged()
        #expect(ready.failed(rejected) == .terminate(rejected))

        var backingOff = policy()
        _ = backingOff.start()
        _ = backingOff.failed(transportCause())
        #expect(backingOff.failed(rejected) == .terminate(rejected))
    }

    /// A replacement that comes up returns the full budget, and says it is a replacement so the
    /// caller replays instead of starting fresh.
    @Test func acknowledgementResetsTheBudgetAndNamesAReplacement() {
        var policy = policy()
        _ = policy.start()
        _ = policy.acknowledged()
        _ = policy.failed(transportCause())
        _ = policy.retryElapsed()
        #expect(policy.acknowledged() == .ready(replacement: true))
        #expect(policy.phase == .ready)

        // Six more retries are available again, so the counter really did reset.
        for _ in 1...6 {
            guard case .retry = policy.failed(transportCause()) else {
                Issue.record("expected a retry"); return
            }
            _ = policy.retryElapsed()
        }
        guard case .terminate = policy.failed(transportCause()) else {
            Issue.record("expected termination"); return
        }
    }

    /// Gemini's `goAway` says the socket is going away on schedule. Replacing it is the plan, so it
    /// must not eat the budget a real failure will need.
    @Test func anExpectedRotationSpendsNoBudget() {
        var policy = policy()
        _ = policy.start()
        _ = policy.acknowledged()

        for _ in 1...3 {
            guard case .open = policy.expectedRotation() else {
                Issue.record("expected a replacement socket"); return
            }
            _ = policy.acknowledged()
        }
        #expect(policy.everReady)
        for _ in 1...6 {
            guard case .retry = policy.failed(transportCause()) else {
                Issue.record("expected a retry"); return
            }
            _ = policy.retryElapsed()
        }
    }

    /// Stop is final: a callback already queued from a socket being torn down must not report
    /// against, or reopen, anything.
    @Test func stopMakesEveryLaterEventIgnored() {
        var policy = policy()
        _ = policy.start()
        _ = policy.acknowledged()
        policy.stop()

        #expect(policy.failed(transportCause()) == .ignore)
        #expect(policy.acknowledged() == .ignore)
        #expect(policy.expectedRotation() == .ignore)
        #expect(policy.retryElapsed() == .ignore)
        #expect(policy.phase == .stopped)
    }

    /// The same holds once a failure has ended the endpoint, so one cause produces one report.
    @Test func terminationIsReportedOnce() {
        var policy = policy()
        _ = policy.start()
        let rejected = ProviderFailure(
            source: source, stage: .close, category: .access, disposition: .permanent,
            identity: .init(closeCode: 3000), message: "")
        #expect(policy.failed(rejected) == .terminate(rejected))
        #expect(policy.failed(rejected) == .ignore)
        #expect(policy.acknowledged() == .ignore)
        #expect(policy.retryElapsed() == .ignore)
    }

    /// A restart is a fresh session, not a continuation: the short budget applies again even though
    /// this instance had a working socket before.
    @Test func startingAgainIsNeverReady() {
        var policy = policy()
        _ = policy.start()
        _ = policy.acknowledged()
        policy.stop()

        #expect(policy.start() == .open(attempt: 1))
        #expect(!policy.everReady)
        _ = policy.failed(transportCause())
        _ = policy.retryElapsed()
        _ = policy.failed(transportCause())
        _ = policy.retryElapsed()
        guard case .terminate(let exhausted) = policy.failed(transportCause()) else {
            Issue.record("expected termination after three attempts"); return
        }
        #expect(exhausted.category == .unreachable)
    }
}
