import Foundation
import JarvisCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Authenticated, attempt-scoped Unix-socket host for one CLI process.
///
/// The sidecar receives only an owner-only ticket path in argv. The ticket contains the bearer
/// token and exact attempt identity; the socket and both config files live beside the session log.
/// `@unchecked Sendable` is limited to this POSIX edge: immutable attempt state is Sendable and
/// `lock` protects every mutable descriptor/file collection.
public final class MCPBridgeHost: @unchecked Sendable {
    /// `lock` protects the task and one-shot result; cancellation publishes a result before cancelling
    /// the task so bridge teardown never waits for a stalled OS capture to return.
    private final class BrokerCall<T>: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var result: Result<T, Error>?
        private var task: Task<Void, Never>?

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            task = nil
            lock.unlock()
            ready.signal()
        }

        func install(_ task: Task<Void, Never>) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                task.cancel()
                return
            }
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = self.task
            self.task = nil
            let shouldSignal = result == nil
            if shouldSignal {
                result = .failure(CancellationError())
            }
            lock.unlock()
            task?.cancel()
            if shouldSignal {
                ready.signal()
            }
        }

        func wait() throws -> T {
            ready.wait()
            lock.lock()
            let result = self.result
            lock.unlock()
            return try result!.get()
        }
    }

    private let sessionDirectory: URL
    private let serverExecutable: URL
    private let broker: CoachingActionBroker
    private let identity: CoachingActionBroker.Identity
    private let lock = NSLock()
    private var started = false
    private var listener: Int32 = -1
    private var activeConnections: Set<Int32> = []
    private var activeCalls: [
        Int32: BrokerCall<CoachingActionBroker.ToolResult>
    ] = [:]
    private var files: [URL] = []

    public init(
        sessionDirectory: URL,
        serverExecutable: URL,
        broker: CoachingActionBroker
    ) {
        self.sessionDirectory = sessionDirectory
        self.serverExecutable = serverExecutable
        self.broker = broker
        self.identity = broker.identity
    }

    deinit {
        close()
    }

    public func start() throws -> CLIMCPConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard !started else {
            throw Self.error("private MCP bridge was started twice")
        }
        started = true
        try Self.requireOwnerOnlyDirectory(sessionDirectory)

        let suffix = identity.attemptID.uuidString.prefix(8).lowercased()
        let socketURL = sessionDirectory.appendingPathComponent("mcp-\(suffix).sock")
        let ticketURL = sessionDirectory.appendingPathComponent("mcp-\(suffix).ticket.json")
        let claudeConfigURL = sessionDirectory.appendingPathComponent("mcp-\(suffix).claude.json")
        let token = Self.randomToken()
        let ticket = MCPBridgeTicket(
            socketPath: socketURL.path,
            token: token,
            attemptID: identity.attemptID,
            configurationRevision: identity.configurationRevision)

        do {
            let descriptor = try UnixSocket.makeListener(path: socketURL.path)
            listener = descriptor
            files = [socketURL, ticketURL, claudeConfigURL]
            try Self.writeOwnerOnly(try JSONEncoder().encode(ticket), to: ticketURL)
            try Self.writeClaudeConfiguration(
                serverExecutable: serverExecutable,
                ticketURL: ticketURL,
                to: claudeConfigURL)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.acceptLoop(descriptor: descriptor, token: token)
            }
            return CLIMCPConfiguration(
                serverExecutable: serverExecutable,
                ticketFile: ticketURL,
                claudeConfigFile: claudeConfigURL)
        } catch {
            let descriptor = listener
            listener = -1
            if descriptor >= 0 { UnixSocket.closeConnection(descriptor) }
            for file in files { try? FileManager.default.removeItem(at: file) }
            files = []
            throw error
        }
    }

    public func close() {
        lock.lock()
        let descriptor = listener
        listener = -1
        let files = self.files
        self.files = []
        if descriptor >= 0 {
            // The accept loop owns the final close. Shutdown wakes `accept` without making this
            // descriptor number available for unrelated process I/O before that loop exits.
            UnixSocket.shutdownConnection(descriptor)
        }
        // Do not close an fd while `handle` may still use its integer: shutdown unblocks the
        // sidecar immediately, and its connection handler remains the sole final-close owner.
        for connection in activeConnections {
            UnixSocket.shutdownConnection(connection)
        }
        let calls = Array(activeCalls.values)
        activeCalls.removeAll()
        lock.unlock()
        for call in calls {
            call.cancel()
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func acceptLoop(descriptor: Int32, token: String) {
        defer {
            lock.lock()
            if listener == descriptor {
                listener = -1
            }
            UnixSocket.closeConnection(descriptor)
            lock.unlock()
        }
        while true {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            let isCurrentListener = listener == descriptor
            if isCurrentListener {
                activeConnections.insert(connection)
            } else {
                UnixSocket.closeConnection(connection)
            }
            lock.unlock()
            guard isCurrentListener else {
                return
            }
            // Parallel MCP calls must overlap at the broker. Serializing connections here would let a
            // terminal generated alongside capture_screen masquerade as evidence-dependent advice.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    UnixSocket.closeConnection(connection)
                    return
                }
                self.handle(connection: connection, token: token)
                self.lock.lock()
                self.activeConnections.remove(connection)
                UnixSocket.closeConnection(connection)
                self.lock.unlock()
            }
        }
    }

    private func handle(connection: Int32, token: String) {
        let response: MCPBridgeResponse
        do {
            let data = try UnixSocket.readMessage(from: connection)
            guard !data.isEmpty else {
                return
            }
            let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
            guard request.token == token,
                  request.attemptID == identity.attemptID,
                  request.configurationRevision == identity.configurationRevision else {
                throw Self.error("private MCP bridge authentication failed")
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try callBroker(request, connection: connection)
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            jlog("Jarvis MCP: \(request.name) completed in \(elapsed)ms")
            switch result {
            case .capture(let snapshot):
                response = .capture(
                    imageBase64: snapshot?.imageBase64,
                    recognizedText: snapshot?.recognizedText)
            case .terminalAccepted:
                response = .terminal
            }
        } catch {
            jlog("Jarvis MCP: action rejected — \(error.localizedDescription)")
            response = .failure(error.localizedDescription)
        }
        if let data = try? JSONEncoder().encode(response) {
            try? UnixSocket.writeMessage(data, to: connection)
        }
    }

    private func callBroker(_ request: MCPBridgeRequest, connection: Int32) throws
        -> CoachingActionBroker.ToolResult {
        let call = BrokerCall<CoachingActionBroker.ToolResult>()
        lock.lock()
        guard listener >= 0, activeConnections.contains(connection) else {
            lock.unlock()
            throw CancellationError()
        }
        activeCalls[connection] = call
        lock.unlock()
        defer {
            lock.lock()
            if activeCalls[connection] === call {
                activeCalls.removeValue(forKey: connection)
            }
            lock.unlock()
        }

        let task = Task { [broker] in
            do {
                let result = try await broker.call(
                    requestID: request.requestID,
                    name: request.name,
                    argumentsJSON: request.argumentsJSON)
                call.finish(.success(result))
            } catch {
                call.finish(.failure(error))
            }
        }
        call.install(task)
        return try call.wait()
    }

    private static func writeClaudeConfiguration(
        serverExecutable: URL,
        ticketURL: URL,
        to url: URL
    ) throws {
        let object: [String: Any] = [
            "mcpServers": [
                "jarvis": [
                    "command": serverExecutable.path,
                    "args": ["--ticket", ticketURL.path],
                    // Claude Code otherwise defers MCP schemas behind its built-in tool-search
                    // surface. Jarvis deliberately disables built-ins, and has only three tiny
                    // actions, so they must be loaded directly.
                    "alwaysLoad": true,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try writeOwnerOnly(data, to: url)
    }

    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw error("couldn't create owner-only private MCP file")
        }
    }

    private static func requireOwnerOnlyDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw error("private MCP bridge requires an owner-only session directory")
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "JarvisMCPBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }
}
