import Foundation

/// Sidecar half of Jarvis's authenticated, attempt-scoped action bridge.
///
/// MCP protocol handling belongs to `JarvisMCPServerCore`; this type only carries one validated
/// tool call over the private Unix socket. Each call uses a fresh connection so pipelined MCP calls
/// remain concurrent at `CoachingActionBroker`.
public struct MCPBridgeClient: Sendable {
    public enum ActionResult: Sendable, Equatable {
        case capture(imageBase64: String?, recognizedText: String?)
        case terminal
        case rejected(String)
    }

    /// `lock` protects the descriptor/cancellation race. Cancellation shuts down the descriptor;
    /// the detached blocking read remains its sole final-close owner.
    private final class CancellableConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32 = -1
        private var cancelled = false

        func connect(path: String) throws -> Int32 {
            let descriptor = try UnixSocket.connect(path: path)
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                UnixSocket.closeConnection(descriptor)
                throw CancellationError()
            }
            self.descriptor = descriptor
            lock.unlock()
            return descriptor
        }

        func finish(_ descriptor: Int32) {
            lock.lock()
            if self.descriptor == descriptor {
                self.descriptor = -1
            }
            lock.unlock()
            UnixSocket.closeConnection(descriptor)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let descriptor = self.descriptor
            lock.unlock()
            if descriptor >= 0 {
                UnixSocket.shutdownConnection(descriptor)
            }
        }

        func checkCancellation() throws {
            lock.lock()
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled {
                throw CancellationError()
            }
        }
    }

    private let ticket: MCPBridgeTicket

    public init(ticketFile: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: ticketFile.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw Self.error("private MCP ticket is not an owner-only regular file")
        }
        self.ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: ticketFile, options: [.mappedIfSafe]))
    }

    public init(arguments: [String]) throws {
        guard let index = arguments.firstIndex(of: "--ticket"),
              arguments.indices.contains(index + 1) else {
            throw Self.error("missing private MCP ticket")
        }
        try self.init(ticketFile: URL(fileURLWithPath: arguments[index + 1]))
    }

    public func call(name: String, argumentsJSON: String) async throws -> ActionResult {
        let connection = CancellableConnection()
        let ticket = self.ticket
        let request = MCPBridgeRequest(
            token: ticket.token,
            attemptID: ticket.attemptID,
            configurationRevision: ticket.configurationRevision,
            requestID: UUID().uuidString.lowercased(),
            name: name,
            argumentsJSON: argumentsJSON)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                let descriptor = try connection.connect(path: ticket.socketPath)
                defer { connection.finish(descriptor) }
                try connection.checkCancellation()
                try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)
                let data = try UnixSocket.readMessage(from: descriptor)
                try connection.checkCancellation()
                let response = try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
                guard response.ok else {
                    return .rejected(
                        response.error ?? "Jarvis rejected the coaching action")
                }
                switch response.kind {
                case .capture:
                    return .capture(
                        imageBase64: response.imageBase64,
                        recognizedText: response.recognizedText)
                case .terminal:
                    return .terminal
                case nil:
                    throw Self.error("Jarvis returned an invalid action result")
                }
            }.value
        } onCancel: {
            connection.cancel()
        }
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "JarvisMCPBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }
}
