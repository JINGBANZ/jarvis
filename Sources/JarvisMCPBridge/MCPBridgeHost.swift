import Foundation
import JarvisCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One authenticated Unix-socket host for a live Jarvis coaching session.
///
/// The listener is reused across coaching attempts. Each attempt leases the host with a fresh bearer
/// token, exact attempt identity, broker, and unique ticket/config paths; ending that lease removes
/// those files and revokes its connections without closing the session listener. The sidecar
/// receives only the owner-only ticket path in argv, keeping the bearer itself out of process
/// listings and traffic records.
///
/// The socket node uses macOS's short per-user temporary directory so deep workspace paths cannot
/// exceed `sockaddr_un.sun_path`. `@unchecked Sendable` is limited to this POSIX edge: `lock`
/// protects every mutable lease, descriptor, and file-lifecycle field.
public final class MCPBridgeHost: @unchecked Sendable {
    public struct Attempt: Sendable {
        public let configuration: CLIMCPConfiguration
        /// Completes after this attempt's terminal MCP result crossed the SDK transport and the
        /// helper's bridge request-ID acknowledgement was confirmed by the host. A provider may
        /// require additional client-observed evidence before the process runner acts on it.
        let completionSignal: AgentCLICompletionSignal
        fileprivate let hostID: UUID
        fileprivate let generation: UInt64
    }

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

        func wait(for interval: DispatchTimeInterval) -> Bool {
            ready.wait(timeout: .now() + interval) == .success
        }

        func value() throws -> T {
            lock.lock()
            let result = self.result
            lock.unlock()
            return try result!.get()
        }
    }

    private struct Lease {
        let generation: UInt64
        let token: String
        let identity: CoachingActionBroker.Identity
        let broker: CoachingActionBroker
        let configuration: CLIMCPConfiguration
        let completionSignal: AgentCLICompletionSignal
    }

    private struct LeaseContext {
        let generation: UInt64
        let broker: CoachingActionBroker
    }

    private struct ActiveBrokerCall {
        let generation: UInt64
        let call: BrokerCall<CoachingActionBroker.ToolResult>
    }

    private let sessionDirectory: URL
    private let serverExecutable: URL
    private let hostID = UUID()
    private let socketSuffix = String(UUID().uuidString.prefix(16)).lowercased()
    private let lock = NSLock()
    private var listenerWasStarted = false
    private var closed = false
    private var listener: Int32 = -1
    private var socketURL: URL?
    private var nextGeneration: UInt64 = 0
    private var activeLease: Lease?
    private var activeConnections: Set<Int32> = []
    private var connectionGenerations: [Int32: UInt64] = [:]
    private var completedConnections: Set<Int32> = []
    private var activeCalls: [Int32: ActiveBrokerCall] = [:]

    public init(
        sessionDirectory: URL,
        serverExecutable: URL
    ) {
        self.sessionDirectory = sessionDirectory
        self.serverExecutable = serverExecutable
    }

    deinit {
        close()
    }

    /// Installs one attempt's broker and rotates its bearer ticket. Exactly one coaching attempt may
    /// lease a session host at a time; `CoachDriver` already serializes attempts.
    public func beginAttempt(
        provider: BrainProvider,
        broker: CoachingActionBroker
    ) throws -> Attempt {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            throw Self.error("private MCP session bridge is closed")
        }
        guard provider.usesLocalCLI else {
            throw Self.error("private MCP bridge requires a local CLI provider")
        }
        guard activeLease == nil else {
            throw Self.error("private MCP bridge already has an active coaching attempt")
        }
        try startListenerIfNeededLocked()

        nextGeneration &+= 1
        let generation = nextGeneration
        let token = Self.randomToken()
        let identity = broker.identity
        let completionSignal = AgentCLICompletionSignal()
        // The filename is independent of the broker identity so even a mistakenly reused attempt UUID
        // cannot let an orphaned helper's old argv path resolve to a newer bearer.
        let attemptSuffix = UUID().uuidString.lowercased()
        let ticketURL = sessionDirectory.appendingPathComponent(
            "mcp-\(attemptSuffix).ticket.json")
        let claudeConfigURL = provider == .claudeCode
            ? sessionDirectory.appendingPathComponent("mcp-\(attemptSuffix).claude.json")
            : nil
        let files = [ticketURL, claudeConfigURL].compactMap { $0 }
        let ticket = MCPBridgeTicket(
            socketPath: socketURL!.path,
            token: token,
            attemptID: identity.attemptID,
            configurationRevision: identity.configurationRevision)
        let configuration = CLIMCPConfiguration(
            serverExecutable: serverExecutable,
            ticketFile: ticketURL,
            claudeConfigFile: claudeConfigURL)

        do {
            try Self.replaceOwnerOnly(try JSONEncoder().encode(ticket), at: ticketURL)
            if let claudeConfigURL {
                try Self.writeClaudeConfiguration(
                    serverExecutable: serverExecutable,
                    ticketURL: ticketURL,
                    to: claudeConfigURL)
            }
        } catch {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            throw error
        }

        activeLease = Lease(
            generation: generation,
            token: token,
            identity: identity,
            broker: broker,
            configuration: configuration,
            completionSignal: completionSignal)
        return Attempt(
            configuration: configuration,
            completionSignal: completionSignal,
            hostID: hostID,
            generation: generation)
    }

    /// Revokes one attempt while leaving the session listener alive. A later attempt must call
    /// `beginAttempt`, which installs a new broker, bearer, and ticket/config paths.
    public func endAttempt(_ attempt: Attempt) {
        lock.lock()
        guard attempt.hostID == hostID,
              let lease = activeLease,
              lease.generation == attempt.generation else {
            lock.unlock()
            return
        }
        activeLease = nil
        let callDescriptors = activeCalls.compactMap { descriptor, active in
            active.generation == attempt.generation ? descriptor : nil
        }
        let calls = callDescriptors.compactMap {
            activeCalls.removeValue(forKey: $0)?.call
        }
        let unfinishedAuthenticatedConnection = connectionGenerations.contains {
            $0.value == attempt.generation && !completedConnections.contains($0.key)
        }
        for connection in activeConnections {
            // `shutdown` unblocks any sidecar still using the old ticket. Its connection handler
            // remains the sole final-close owner, avoiding descriptor-reuse races.
            UnixSocket.shutdownConnection(connection)
        }
        for file in Self.files(for: lease.configuration) {
            try? FileManager.default.removeItem(at: file)
        }
        lock.unlock()

        for call in calls {
            call.cancel()
        }
        if !calls.isEmpty || unfinishedAuthenticatedConnection {
            lease.broker.invalidate()
        }
    }

    /// Tears down the whole session transport. A closed host is never reopened; a new Start creates a
    /// new host, listener, and socket path.
    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let lease = activeLease
        activeLease = nil
        let descriptor = listener
        listener = -1
        let socketURL = self.socketURL
        if descriptor >= 0 {
            // `shutdown` does not wake `accept` on a listening Darwin socket. Close while holding
            // the ownership lock; the accept-loop defer checks ownership before touching this fd
            // number again, so reuse cannot close unrelated process I/O.
            UnixSocket.closeConnection(descriptor)
        }
        for connection in activeConnections {
            UnixSocket.shutdownConnection(connection)
        }
        let calls = activeCalls.values.map(\.call)
        activeCalls.removeAll()
        lock.unlock()

        lease?.broker.invalidate()
        for call in calls {
            call.cancel()
        }
        let leaseFiles = lease.map { Self.files(for: $0.configuration) } ?? []
        for file in [socketURL].compactMap({ $0 }) + leaseFiles {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func startListenerIfNeededLocked() throws {
        if listener >= 0 { return }
        guard !listenerWasStarted else {
            throw Self.error("private MCP session listener is unavailable")
        }
        try Self.requireOwnerOnlyDirectory(sessionDirectory)
        let socketURL = try Self.socketURL(suffix: socketSuffix)
        do {
            let descriptor = try UnixSocket.makeListener(path: socketURL.path)
            listenerWasStarted = true
            listener = descriptor
            self.socketURL = socketURL
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Deinitialization closes the listener when the host disappears before this block
                // starts; never touch the captured fd number after that close because it may be
                // reused by unrelated process I/O.
                guard let self else { return }
                self.acceptLoop(descriptor: descriptor)
            }
        } catch {
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }
    }

    private func acceptLoop(descriptor: Int32) {
        defer {
            lock.lock()
            let ownsListener = listener == descriptor
            if ownsListener {
                listener = -1
                UnixSocket.closeConnection(descriptor)
            }
            lock.unlock()
        }
        while true {
            let connection: Int32
            do {
                connection = try UnixSocket.acceptConnection(from: descriptor)
            } catch {
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
                self.handle(connection: connection)
                self.lock.lock()
                self.activeConnections.remove(connection)
                self.connectionGenerations.removeValue(forKey: connection)
                self.completedConnections.remove(connection)
                UnixSocket.closeConnection(connection)
                self.lock.unlock()
            }
        }
    }

    private func handle(connection: Int32) {
        let response: MCPBridgeResponse
        var context: LeaseContext?
        var deliveryRequestID: String?
        var captureRequestID: String?
        var terminalWasAccepted = false
        do {
            let data = try UnixSocket.readMessage(from: connection)
            guard !data.isEmpty else {
                return
            }
            let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
            let started = DispatchTime.now().uptimeNanoseconds
            let authorized = try callBroker(request, connection: connection)
            context = authorized.context
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            jlog("Jarvis MCP: \(request.name) completed in \(elapsed)ms")
            deliveryRequestID = request.requestID
            switch authorized.result {
            case .capture(let snapshot):
                captureRequestID = request.requestID
                response = .capture(
                    imageBase64: snapshot?.imageBase64,
                    recognizedText: snapshot?.recognizedText)
            case .terminalAccepted:
                terminalWasAccepted = true
                response = .terminal
            }
        } catch {
            jlog("Jarvis MCP: action rejected — \(error.localizedDescription)")
            response = .failure(error.localizedDescription)
        }
        do {
            try UnixSocket.writeMessage(
                JSONEncoder().encode(response),
                to: connection)
            if let deliveryRequestID, let context {
                let data = try UnixSocket.readMessage(from: connection)
                guard !data.isEmpty else {
                    throw Self.error("private MCP result was not acknowledged")
                }
                let acknowledgement = try JSONDecoder().decode(
                    MCPBridgeAcknowledgement.self,
                    from: data)
                guard acknowledgement.requestID == deliveryRequestID else {
                    throw Self.error("private MCP acknowledgement did not match its request")
                }
                if let captureRequestID {
                    try acknowledgeCaptureDelivery(
                        requestID: captureRequestID,
                        context: context)
                }
                try UnixSocket.writeMessage(
                    JSONEncoder().encode(acknowledgement),
                    to: connection)
                markConnectionCompleted(
                    connection,
                    context: context,
                    terminalWasDelivered: terminalWasAccepted)
            }
        } catch {
            // An accepted action is useful only if its result reaches the agent. In particular, a
            // capture whose reply is lost must not authorize a later screen-grounded terminal.
            if response.ok {
                context?.broker.invalidate()
            }
            jlog("Jarvis MCP: response delivery failed — \(error.localizedDescription)")
        }
    }

    private func callBroker(
        _ request: MCPBridgeRequest,
        connection: Int32
    ) throws -> (result: CoachingActionBroker.ToolResult, context: LeaseContext) {
        let call = BrokerCall<CoachingActionBroker.ToolResult>()
        lock.lock()
        guard listener >= 0,
              activeConnections.contains(connection),
              let lease = activeLease,
              request.token == lease.token,
              request.attemptID == lease.identity.attemptID,
              request.configurationRevision == lease.identity.configurationRevision else {
            lock.unlock()
            throw Self.error("private MCP bridge authentication failed")
        }
        let context = LeaseContext(
            generation: lease.generation,
            broker: lease.broker)
        connectionGenerations[connection] = lease.generation
        activeCalls[connection] = ActiveBrokerCall(
            generation: lease.generation,
            call: call)
        lock.unlock()
        defer {
            lock.lock()
            if activeCalls[connection]?.call === call {
                activeCalls.removeValue(forKey: connection)
            }
            lock.unlock()
        }

        let task = Task { [broker = context.broker] in
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
        while !call.wait(for: .milliseconds(25)) {
            if UnixSocket.peerHasClosed(connection) {
                // A cancelled MCP request must not finish capturing or stage an action after the
                // SDK has discarded its response. Invalidate the whole attempt before cancelling
                // the blocked broker task; the next scheduler attempt starts with fresh state.
                context.broker.invalidate()
                call.cancel()
                throw CancellationError()
            }
        }
        return (try call.value(), context)
    }

    private func acknowledgeCaptureDelivery(
        requestID: String,
        context: LeaseContext
    ) throws {
        lock.lock()
        let isActive = activeLease?.generation == context.generation
        lock.unlock()
        guard isActive else { throw CancellationError() }

        let call = BrokerCall<Bool>()
        let task = Task { [broker = context.broker] in
            do {
                call.finish(.success(
                    try await broker.acknowledgeCaptureDelivery(requestID: requestID)))
            } catch {
                call.finish(.failure(error))
            }
        }
        call.install(task)
        while !call.wait(for: .milliseconds(25)) {}
        guard try call.value() else {
            throw Self.error("capture delivery did not match a brokered request")
        }
    }

    private func markConnectionCompleted(
        _ connection: Int32,
        context: LeaseContext,
        terminalWasDelivered: Bool = false
    ) {
        var completionSignal: AgentCLICompletionSignal?
        lock.lock()
        if connectionGenerations[connection] == context.generation,
           activeLease?.generation == context.generation {
            completedConnections.insert(connection)
            if terminalWasDelivered {
                completionSignal = activeLease?.completionSignal
            }
        }
        lock.unlock()
        // Signal outside the host lock. The process runner callback can synchronously wake and
        // terminate the agent CLI; it must never re-enter bridge lifecycle while this lock is held.
        completionSignal?.signal(.terminalActionDelivered)
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
                    // surface. Jarvis deliberately disables built-ins, so the supplied coaching
                    // actions must be loaded directly.
                    "alwaysLoad": true,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try replaceOwnerOnly(data, at: url)
    }

    private static func files(for configuration: CLIMCPConfiguration) -> [URL] {
        [configuration.ticketFile, configuration.claudeConfigFile].compactMap { $0 }
    }

    /// Atomically installs a fresh owner-only inode so readers never see a partial ticket or config.
    private static func replaceOwnerOnly(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw error("couldn't create owner-only private MCP file")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func socketURL(suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-mcp-\(getuid())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try requireOwnerOnlyDirectory(directory)
        return directory.appendingPathComponent("m-\(suffix).sock")
    }

    private static func requireOwnerOnlyDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() else {
            throw error("private MCP bridge requires an owner-only directory")
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
