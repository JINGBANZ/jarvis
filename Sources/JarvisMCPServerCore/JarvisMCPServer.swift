import Foundation
import JarvisCore
import JarvisMCPBridge
import MCP

/// Official-SDK MCP adapter for Jarvis's private action broker.
///
/// The SDK owns JSON-RPC framing, lifecycle, version negotiation, request concurrency, and
/// cancellation. This adapter owns only the three tool descriptors and result translation.
public enum JarvisMCPServer {
    public static func run(arguments: [String] = CommandLine.arguments) async throws {
        let bridge = try MCPBridgeClient(arguments: arguments)
        let server = try await makeServer(bridge: bridge)
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        await server.stop()
    }

    static func toolDescriptors() throws -> [Tool] {
        try coachTools.map { definition in
            let schema = try JSONDecoder().decode(
                Value.self,
                from: Data(definition.parametersJSON.utf8))
            let annotations: Tool.Annotations
            switch definition.name {
            case captureScreenTool.name:
                annotations = .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false)
            case speakTool.name:
                annotations = .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false)
            default:
                annotations = .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false)
            }
            return Tool(
                name: definition.name,
                description: definition.description,
                inputSchema: schema,
                annotations: annotations)
        }
    }

    static func makeServer(bridge: MCPBridgeClient) async throws -> Server {
        let server = Server(
            name: "jarvis-actions",
            version: "1.0.0",
            instructions: "Call coaching actions serially. End every turn with speak or stay_silent.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .strict)
        let tools = try toolDescriptors()

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            let arguments = Value.object(parameters.arguments ?? [:])
            let argumentsJSON = String(
                decoding: try JSONEncoder().encode(arguments),
                as: UTF8.self)
            switch try await bridge.call(
                name: parameters.name,
                argumentsJSON: argumentsJSON
            ) {
            case .rejected(let message):
                return CallTool.Result(
                    content: [.text(text: message, annotations: nil, _meta: nil)],
                    isError: true)

            case .capture(let imageBase64, let recognizedText):
                let text = recognizedText.map {
                    "screenshot captured\n\nOn-device OCR (the image is ground truth):\n\($0)"
                } ?? (imageBase64 == nil ? "screenshot failed" : "screenshot captured")
                var content: [Tool.Content] = [
                    .text(text: text, annotations: nil, _meta: nil),
                ]
                if let imageBase64 {
                    content.append(.image(
                        data: imageBase64,
                        mimeType: "image/jpeg",
                        annotations: nil,
                        _meta: nil))
                }
                return CallTool.Result(content: content)

            case .terminal:
                return CallTool.Result(content: [
                    .text(text: "action accepted", annotations: nil, _meta: nil),
                ])
            }
        }
        return server
    }
}
