import Foundation
import Testing
@testable import JarvisCore

@Suite struct RetryingBrainClientTests {
    @Test func retriesOneTransientFailure() async throws {
        let base = RetryScriptBrain(script: [
            .failure(URLError(.timedOut)),
            .success(.init(toolCalls: [.staySilent(callId: "ok")])),
        ])
        let client = RetryingBrainClient(base: base)

        let response = try await client.respond(messages: [.user("hi")], tools: coachTools)

        #expect(response.toolCalls == [.staySilent(callId: "ok")])
        #expect(base.callCount == 2)
    }

    @Test func stopsAfterSecondTransientFailure() async {
        let base = RetryScriptBrain(script: [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)),
        ])
        let client = RetryingBrainClient(base: base)

        await #expect(throws: BrainFailure.self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        #expect(base.callCount == 2)
    }

    @Test func retriesTransientServerFailure() async throws {
        let base = RetryScriptBrain(script: [
            .failure(BrainFailure.openAIHTTP(
                status: 503, errorCode: nil, errorType: nil, detail: "unavailable")),
            .success(.init(toolCalls: [.staySilent(callId: "ok")])),
        ])
        let client = RetryingBrainClient(base: base)

        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)

        #expect(base.callCount == 2)
    }

    @Test func doesNotRetryPermanentFailure() async {
        let error = BrainFailure.openAIHTTP(
            status: 401, errorCode: "invalid_api_key", errorType: nil, detail: "unauthorized")
        let base = RetryScriptBrain(script: [.failure(error)])
        let client = RetryingBrainClient(base: base)

        await #expect(throws: BrainFailure.self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        #expect(base.callCount == 1)
    }

    @Test func doesNotImmediatelyRetryCLIWatchdogTimeout() async {
        let error = NSError(
            domain: AgentCLIProcessRunner.errorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "codex timed out"]
        )
        let base = RetryScriptBrain(script: [.failure(error)])
        let client = RetryingBrainClient(base: base)

        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        #expect(base.callCount == 1)
    }

    @Test func rateLimitPreservesSessionButDoesNotRetryImmediately() async {
        let base = RetryScriptBrain(script: [
            .failure(BrainFailure.openAIHTTP(
                status: 429, errorCode: "rate_limit_exceeded", errorType: nil, detail: "limited")),
        ])
        let client = RetryingBrainClient(base: base)

        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected a classified rate-limit failure")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .temporary)
            #expect(!failure.retriesImmediately)
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
        #expect(base.callCount == 1)
    }

    @Test func unknownFutureFailurePreservesSessionWithoutSpeculativeRetry() async {
        let base = RetryScriptBrain(script: [
            .failure(NSError(domain: "FutureProvider", code: 1)),
        ])
        let client = RetryingBrainClient(base: base)

        do {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
            Issue.record("expected a classified future failure")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .temporary)
            #expect(!failure.retriesImmediately)
        } catch {
            Issue.record("expected BrainFailure, got \(error)")
        }
        #expect(base.callCount == 1)
    }
}

// SAFETY: `script` and `calls` are the only mutable state and every access is guarded by `lock`.
private final class RetryScriptBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<BrainResponse, Error>]
    private var calls = 0

    init(script: [Result<BrainResponse, Error>]) {
        self.script = script
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        let result = lock.withLock {
            calls += 1
            return script.removeFirst()
        }
        return try result.get()
    }
}
