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

        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        #expect(base.callCount == 2)
    }

    @Test func retriesTransientServerFailure() async throws {
        let base = RetryScriptBrain(script: [
            .failure(NSError(domain: "OpenAIBrainClient", code: 503)),
            .success(.init(toolCalls: [.staySilent(callId: "ok")])),
        ])
        let client = RetryingBrainClient(base: base)

        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)

        #expect(base.callCount == 2)
    }

    @Test func retriesCLISubprocessTimeout() async throws {
        let base = RetryScriptBrain(script: [
            .failure(NSError(domain: "AgentCLIProcessRunner", code: NSURLErrorTimedOut)),
            .success(.init(toolCalls: [.staySilent(callId: "ok")])),
        ])
        let client = RetryingBrainClient(base: base)

        _ = try await client.respond(messages: [.user("hi")], tools: coachTools)

        #expect(base.callCount == 2)
    }

    @Test func doesNotRetryNonTimeoutCLIError() async {
        let base = RetryScriptBrain(script: [
            .failure(NSError(domain: "AgentCLIProcessRunner", code: 1)),
        ])
        let client = RetryingBrainClient(base: base)

        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
        }
        #expect(base.callCount == 1)
    }

    @Test func doesNotRetryPermanentFailure() async {
        let error = NSError(domain: "OpenAIBrainClient", code: 401)
        let base = RetryScriptBrain(script: [.failure(error)])
        let client = RetryingBrainClient(base: base)

        await #expect(throws: (any Error).self) {
            _ = try await client.respond(messages: [.user("hi")], tools: coachTools)
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
