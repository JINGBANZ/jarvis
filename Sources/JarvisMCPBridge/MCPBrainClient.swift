import Foundation
import JarvisCore

/// CLI brain adapter that leases one private action surface from the live session's MCP bridge.
/// Tool-less auxiliary calls continue through the plain CLI client and never start the listener.
public struct MCPBrainClient: BrainClient, Sendable {
    private let base: CLIBrainClient
    private let bridge: MCPBridgeHost

    public init(
        base: CLIBrainClient,
        bridge: MCPBridgeHost
    ) {
        self.base = base
        self.bridge = bridge
    }

    public func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) async throws -> BrainResponse {
        try await base.respond(messages: messages, tools: tools, toolChoice: toolChoice)
    }

    public func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice,
        actionBroker: CoachingActionBroker
    ) async throws -> BrainResponse {
        guard !tools.isEmpty else {
            return try await base.respond(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice)
        }

        let attempt: MCPBridgeHost.Attempt
        do {
            attempt = try bridge.beginAttempt(
                provider: base.provider,
                broker: actionBroker)
        } catch {
            throw BrainFailure(
                disposition: .temporary,
                detail: "private MCP bridge unavailable: \(error.localizedDescription)")
        }
        defer { bridge.endAttempt(attempt) }
        let response = try await base.respondUsingMCP(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            configuration: attempt.configuration,
            // The brokered terminal action is the authoritative result. The signal proves its MCP
            // response crossed the SDK transport; Claude additionally waits until its JSONL stream
            // emits the matching accepted tool result before the runner terminates it.
            completionSignal: attempt.completionSignal)
        _ = try await actionBroker.requireTerminal()
        return response
    }
}
