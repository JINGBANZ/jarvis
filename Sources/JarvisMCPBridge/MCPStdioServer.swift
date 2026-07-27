import Foundation
import JarvisCore

/// Minimal stdio JSON-RPC MCP server. It owns no action policy: every `tools/call` is forwarded to
/// the authenticated attempt host, which validates and stages it in `CoachingActionBroker`.
public enum MCPStdioServer {
    private actor ResponseWriter {
        func write(_ data: Data) throws {
            var framed = data
            framed.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: framed)
        }
    }

    private struct JSONRPCFailure: Error, LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }

    public static func run(arguments: [String] = CommandLine.arguments) async throws {
        let ticketURL = try parseTicketURL(arguments)
        let ticket = try loadTicket(ticketURL)
        let writer = ResponseWriter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var inputSequence = 0
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty else { continue }
                inputSequence += 1
                let actionSequence = inputSequence
                // MCP clients may pipeline a parallel tool batch. Start each request immediately so
                // the broker can detect the overlap instead of falsely serializing model decisions.
                group.addTask {
                    if let response = try responseData(
                        forLine: line,
                        ticket: ticket,
                        actionSequence: actionSequence
                    ) {
                        try await writer.write(response)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    static func responseData(
        forLine line: String,
        ticket: MCPBridgeTicket,
        actionSequence: Int
    ) throws -> Data? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
        } catch {
            return try encodedResponse(
                id: NSNull(),
                errorCode: -32700,
                message: "Parse error")
        }
        guard let request = parsed as? [String: Any] else {
            return try encodedResponse(
                id: NSNull(),
                errorCode: -32600,
                message: "Invalid Request")
        }

        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return try encodedResponse(
                id: request.keys.contains("id") ? id : NSNull(),
                errorCode: -32600,
                message: "Invalid Request")
        }
        if method.hasPrefix("notifications/") || !request.keys.contains("id") {
            return nil
        }

        do {
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "result": try result(
                    for: method,
                    request: request,
                    ticket: ticket,
                    actionSequence: actionSequence),
            ])
        } catch let failure as JSONRPCFailure {
            return try encodedResponse(
                id: id,
                errorCode: failure.code,
                message: failure.message)
        } catch {
            return try encodedResponse(
                id: id,
                errorCode: -32603,
                message: error.localizedDescription)
        }
    }

    public static func toolDescriptors() throws -> [[String: Any]] {
        try [captureScreenTool, speakTool, staySilentTool].map { tool in
            guard let schema = try JSONSerialization.jsonObject(
                with: Data(tool.parametersJSON.utf8)) as? [String: Any] else {
                throw error("invalid Jarvis tool schema")
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": schema,
            ]
        }
    }

    private static func result(
        for method: String,
        request: [String: Any],
        ticket: MCPBridgeTicket,
        actionSequence: Int
    ) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = ((request["params"] as? [String: Any])?["protocolVersion"] as? String)
                ?? "2024-11-05"
            return [
                "protocolVersion": requested,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "jarvis-actions", "version": "1.0.0"],
            ]

        case "ping":
            return [:]

        case "tools/list":
            return ["tools": try toolDescriptors()]

        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                throw JSONRPCFailure(
                    code: -32602,
                    message: "tools/call requires a tool name")
            }
            let arguments: [String: Any]
            if let suppliedArguments = params["arguments"] {
                guard let object = suppliedArguments as? [String: Any] else {
                    throw JSONRPCFailure(
                        code: -32602,
                        message: "tools/call arguments must be an object")
                }
                arguments = object
            } else {
                arguments = [:]
            }
            let argumentsData = try JSONSerialization.data(
                withJSONObject: arguments,
                options: [.sortedKeys])
            let bridgeRequest = MCPBridgeRequest(
                token: ticket.token,
                attemptID: ticket.attemptID,
                configurationRevision: ticket.configurationRevision,
                requestID: "mcp-\(actionSequence)",
                name: name,
                argumentsJSON: String(decoding: argumentsData, as: UTF8.self))
            let bridgeResponse = try callHost(bridgeRequest, ticket: ticket)
            guard bridgeResponse.ok else {
                return [
                    "isError": true,
                    "content": [[
                        "type": "text",
                        "text": bridgeResponse.error ?? "Jarvis rejected the coaching action",
                    ]],
                ]
            }
            switch bridgeResponse.kind {
            case .capture:
                var content: [[String: Any]] = []
                let text = bridgeResponse.recognizedText.map {
                    "screenshot captured\n\nOn-device OCR (the image is ground truth):\n\($0)"
                } ?? (bridgeResponse.imageBase64 == nil
                       ? "screenshot failed"
                       : "screenshot captured")
                content.append(["type": "text", "text": text])
                if let image = bridgeResponse.imageBase64 {
                    content.append([
                        "type": "image",
                        "data": image,
                        "mimeType": "image/jpeg",
                    ])
                }
                return ["content": content]

            case .terminal:
                return ["content": [["type": "text", "text": "action accepted"]]]

            case nil:
                throw error("Jarvis returned an invalid action result")
            }

        default:
            throw JSONRPCFailure(code: -32601, message: "method not found: \(method)")
        }
    }

    private static func callHost(
        _ request: MCPBridgeRequest,
        ticket: MCPBridgeTicket
    ) throws -> MCPBridgeResponse {
        let descriptor = try UnixSocket.connect(path: ticket.socketPath)
        defer { UnixSocket.closeConnection(descriptor) }
        try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)
        let data = try UnixSocket.readMessage(from: descriptor)
        return try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
    }

    private static func parseTicketURL(_ arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: "--ticket"),
              arguments.indices.contains(index + 1) else {
            throw error("missing private MCP ticket")
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func loadTicket(_ url: URL) throws -> MCPBridgeTicket {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o077 == 0 else {
            throw error("private MCP ticket is not owner-only")
        }
        return try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private static func encodedResponse(
        id: Any,
        errorCode: Int,
        message: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": errorCode,
                "message": message,
            ],
        ])
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "JarvisMCPBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }
}
