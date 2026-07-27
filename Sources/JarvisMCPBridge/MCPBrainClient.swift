import Foundation
import JarvisCore

/// CLI brain adapter that gives one agent process one private, attempt-scoped MCP action surface.
/// Tool-less auxiliary calls continue through the plain CLI client and never start a server.
public struct MCPBrainClient: BrainClient, Sendable {
    private let base: CLIBrainClient
    private let sessionDirectory: URL
    private let serverExecutable: URL

    public init(
        base: CLIBrainClient,
        sessionDirectory: URL,
        serverExecutable: URL
    ) {
        self.base = base
        self.sessionDirectory = sessionDirectory
        self.serverExecutable = serverExecutable
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

        let host = MCPBridgeHost(
            sessionDirectory: sessionDirectory,
            serverExecutable: serverExecutable,
            broker: actionBroker)
        let configuration: CLIMCPConfiguration
        do {
            configuration = try host.start()
        } catch {
            throw BrainFailure(
                disposition: .temporary,
                detail: "private MCP bridge unavailable: \(error.localizedDescription)")
        }
        defer { host.close() }
        let response = try await base.respondUsingMCP(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            configuration: configuration)
        _ = try await actionBroker.requireTerminal()
        return response
    }
}
