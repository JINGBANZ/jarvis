import Foundation

/// Adds one automatic retry when the shared `BrainFailure` policy says the exact self-contained
/// request is safe to repeat. Tool calls have no client-side effect until a response reaches
/// `CoachDriver`, so retrying a request whose response was lost cannot duplicate a screenshot or
/// spoken tip. The same typed failure then reaches the driver, preventing retry and session
/// lifecycle from independently—and inconsistently—reclassifying it.
public struct RetryingBrainClient: BrainClient, Sendable {
    private let base: BrainClient

    public init(base: BrainClient) {
        self.base = base
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        do {
            return try await base.respond(messages: messages, tools: tools, toolChoice: toolChoice)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            let failure = BrainFailure(error)
            guard failure.retriesImmediately else { throw failure }
            jlog("Jarvis coach: transient brain request failure — retrying once: \(failure.detail)")
            do {
                return try await base.respond(
                    messages: messages, tools: tools, toolChoice: toolChoice)
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                throw BrainFailure(error)
            }
        }
    }
}
