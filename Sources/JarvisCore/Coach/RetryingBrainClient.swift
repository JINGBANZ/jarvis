import Foundation

/// Adds one automatic retry for transient transport/server failures around a self-contained brain
/// request. Tool calls have no client-side effect until a response reaches `CoachDriver`, so retrying
/// a request whose response was lost cannot duplicate a screenshot or spoken tip. Permanent HTTP
/// failures and cancellation still fail immediately.
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
            guard !Task.isCancelled, Self.isTransient(error) else { throw error }
            jlog("Jarvis coach: transient brain request failure — retrying once: \(error.localizedDescription)")
            return try await base.respond(messages: messages, tools: tools, toolChoice: toolChoice)
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorSecureConnectionFailed,
            ].contains(ns.code)
        }
        if ns.domain == "OpenAIBrainClient" {
            return [408, 409, 500, 502, 503, 504].contains(ns.code)
        }
        return false
    }
}
