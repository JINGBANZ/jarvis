import Foundation

/// Sidecar half of one authenticated attempt lease on Jarvis's session-scoped action bridge.
///
/// MCP protocol handling belongs to `JarvisMCPServerCore`; this type only carries one validated
/// tool call over the private Unix socket. Each call uses a fresh connection so pipelined MCP calls
/// remain concurrent at `CoachingActionBroker`.
public struct MCPBridgeClient: Sendable {
    public enum ActionResult: Sendable {
        case capture(
            imageBase64: String?,
            recognizedText: String?,
            delivery: Delivery
        )
        case terminal(delivery: Delivery)
        case rejected(String)
    }

    /// One accepted broker result awaiting successful MCP-transport delivery.
    ///
    /// The bridge connection stays open after `call` returns. Only the SDK transport wrapper may
    /// confirm it, after writing the corresponding `tools/call` response. Cancellation or a dropped
    /// receipt closes the connection instead, which makes the host invalidate the attempt.
    public final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32 = -1
        private var cancelled = false
        private let requestID: String

        fileprivate init(requestID: String) {
            self.requestID = requestID
        }

        deinit {
            cancel()
            finish()
        }

        fileprivate func connect(path: String) throws -> Int32 {
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

        fileprivate func finish() {
            lock.lock()
            let descriptor = self.descriptor
            self.descriptor = -1
            if descriptor >= 0 {
                // Final-close while holding the ownership lock so a concurrent cancel cannot retain
                // this numeric fd past its lifetime and shut down an unrelated reused socket.
                UnixSocket.closeConnection(descriptor)
            }
            lock.unlock()
        }

        public func cancel() {
            lock.lock()
            cancelled = true
            if descriptor >= 0 {
                UnixSocket.shutdownConnection(descriptor)
            }
            lock.unlock()
        }

        /// Confirm only after the official SDK transport successfully writes the tool response.
        public func confirm() async throws {
            try await Task.detached {
                try self.confirmBlocking()
            }.value
        }

        private func confirmBlocking() throws {
            lock.lock()
            guard !cancelled, descriptor >= 0 else {
                lock.unlock()
                throw CancellationError()
            }
            let descriptor = self.descriptor
            lock.unlock()
            defer { finish() }

            let acknowledgement = MCPBridgeAcknowledgement(requestID: requestID)
            try UnixSocket.writeMessage(
                try JSONEncoder().encode(acknowledgement),
                to: descriptor)
            let confirmationData = try UnixSocket.readMessage(from: descriptor)
            guard try JSONDecoder().decode(
                MCPBridgeAcknowledgement.self,
                from: confirmationData) == acknowledgement else {
                throw Self.error("Jarvis did not confirm action delivery")
            }
        }

        fileprivate func checkCancellation() throws {
            lock.lock()
            let isCancelled = cancelled
            lock.unlock()
            if isCancelled { throw CancellationError() }
        }

        private static func error(_ description: String) -> NSError {
            NSError(
                domain: "JarvisMCPBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
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
        let request = MCPBridgeRequest(
            token: ticket.token,
            attemptID: ticket.attemptID,
            configurationRevision: ticket.configurationRevision,
            requestID: UUID().uuidString.lowercased(),
            name: name,
            argumentsJSON: argumentsJSON)
        let delivery = Delivery(requestID: request.requestID)
        let ticket = self.ticket

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                let descriptor = try delivery.connect(path: ticket.socketPath)
                var retainForTransportDelivery = false
                defer {
                    if !retainForTransportDelivery {
                        delivery.finish()
                    }
                }
                try delivery.checkCancellation()
                try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)
                let data = try UnixSocket.readMessage(from: descriptor)
                try delivery.checkCancellation()
                let response = try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
                guard response.ok else {
                    return .rejected(
                        response.error ?? "Jarvis rejected the coaching action")
                }
                retainForTransportDelivery = true
                switch response.kind {
                case .capture:
                    return .capture(
                        imageBase64: response.imageBase64,
                        recognizedText: response.recognizedText,
                        delivery: delivery)
                case .terminal:
                    return .terminal(delivery: delivery)
                case nil:
                    retainForTransportDelivery = false
                    throw Self.error("Jarvis returned an invalid action result")
                }
            }.value
        } onCancel: {
            delivery.cancel()
        }
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "JarvisMCPBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }
}
