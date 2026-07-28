import Foundation
import Testing
@testable import JarvisCore
@testable import JarvisMCPBridge
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized) struct MCPBridgeTests {
    /// `@unchecked Sendable` is safe because `lock` guards the only mutable state.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func next() -> Int {
            lock.lock()
            storage += 1
            let value = storage
            lock.unlock()
            return value
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private actor CaptureGate {
        private let snapshot: ScreenSnapshot?
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        init(snapshot: ScreenSnapshot? = nil) {
            self.snapshot = snapshot
        }

        func capture() async -> ScreenSnapshot? {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { releaseWaiter = $0 }
            return snapshot
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private static func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("jmcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func exchange(
        _ request: MCPBridgeRequest,
        ticket: MCPBridgeTicket
    ) throws -> MCPBridgeResponse {
        let descriptor = try UnixSocket.connect(path: ticket.socketPath)
        defer { UnixSocket.closeConnection(descriptor) }
        try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)
        return try JSONDecoder().decode(
            MCPBridgeResponse.self,
            from: UnixSocket.readMessage(from: descriptor))
    }

    private static func listenerDescriptor(path: String) -> Int32? {
        let limit = min(Int(getdtablesize()), 4_096)
        for candidate in 0..<limit {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(Int32(candidate), $0, &length)
                }
            }
            guard result == 0, address.sun_family == sa_family_t(AF_UNIX) else {
                continue
            }
            let candidatePath = withUnsafePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: UnixSocket.maximumPathBytes) {
                    String(cString: $0)
                }
            }
            if candidatePath == path {
                return Int32(candidate)
            }
        }
        return nil
    }

    @Test func bridgeRejectsALooseSessionDirectory() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path)
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)

        #expect(throws: (any Error).self) {
            _ = try host.start()
        }
    }

    @Test func authenticatedSocketForwardsActionsAndCleansUpAttemptFiles() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = ScreenSnapshot(
            imageBase64: Data("synthetic-jpeg".utf8).base64EncodedString(),
            recognizedText: "synthetic screen")
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 9),
            capture: { shot })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        let configuration = try host.start()
        let ticketData = try Data(contentsOf: configuration.ticketFile)
        let ticket = try JSONDecoder().decode(MCPBridgeTicket.self, from: ticketData)

        let permissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: configuration.ticketFile.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        #expect(try FileManager.default.attributesOfItem(
            atPath: ticket.socketPath)[.posixPermissions] as? NSNumber == 0o600)

        let capture = try Self.exchange(
            MCPBridgeRequest(
                token: ticket.token,
                attemptID: ticket.attemptID,
                configurationRevision: ticket.configurationRevision,
                requestID: "capture",
                name: captureScreenTool.name,
                argumentsJSON: "{}"),
            ticket: ticket)
        #expect(capture.imageBase64 == shot.imageBase64)
        #expect(capture.recognizedText == shot.recognizedText)

        let terminal = try Self.exchange(
            MCPBridgeRequest(
                token: ticket.token,
                attemptID: ticket.attemptID,
                configurationRevision: ticket.configurationRevision,
                requestID: "speak",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["Use the synthetic evidence."]}"#),
            ticket: ticket)
        #expect(terminal.ok)
        #expect(try await broker.commit()
                == .speak(callID: "speak", lines: ["Use the synthetic evidence."]))

        let protectedFiles = [
            URL(fileURLWithPath: ticket.socketPath),
            configuration.ticketFile,
            configuration.claudeConfigFile,
        ]
        host.close()
        #expect(protectedFiles.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test func wrongBearerTokenCannotReachTheBroker() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 2),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }
        let configuration = try host.start()
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        let response = try Self.exchange(
            MCPBridgeRequest(
                token: "wrong",
                attemptID: ticket.attemptID,
                configurationRevision: ticket.configurationRevision,
                requestID: "speak",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["This must not render."]}"#),
            ticket: ticket)

        #expect(!response.ok)
        do {
            _ = try await broker.requireTerminal()
            Issue.record("unauthenticated action reached the broker")
        } catch let failure as CoachingActionBroker.Failure {
            #expect(failure == .missingTerminal)
        }
    }

    @Test func closingHostUnblocksAnActiveSidecarConnection() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 3),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        let configuration = try host.start()
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        let descriptor = try UnixSocket.connect(path: ticket.socketPath)
        defer { UnixSocket.closeConnection(descriptor) }

        try await Task.sleep(for: .milliseconds(50))
        host.close()

        #expect(try UnixSocket.readMessage(from: descriptor).isEmpty)
    }

    @Test func closingIdleHostClosesTheListeningDescriptor() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 31),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        let configuration = try host.start()
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        let descriptor = try #require(Self.listenerDescriptor(path: ticket.socketPath))

        host.close()

        errno = 0
        let status = fcntl(descriptor, F_GETFD)
        let error = errno
        #expect(status == -1)
        #expect(error == EBADF)
    }

    @Test func closingHostCancelsAnInFlightBrokerCallBeforeCaptureReturns() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CaptureGate()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 4),
            capture: { await gate.capture() })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        let configuration = try host.start()
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        let completed = Counter()
        let request = MCPBridgeRequest(
            token: ticket.token,
            attemptID: ticket.attemptID,
            configurationRevision: ticket.configurationRevision,
            requestID: "stalled-capture",
            name: captureScreenTool.name,
            argumentsJSON: "{}")
        let exchange = Task.detached {
            defer { _ = completed.next() }
            return Result { try Self.exchange(request, ticket: ticket) }
        }

        await gate.waitUntilEntered()
        host.close()
        for _ in 0..<50 where completed.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.value == 1)

        await gate.release()
        _ = await exchange.value
    }

    @Test func undeliverableCaptureReplyInvalidatesTheAttempt() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = ScreenSnapshot(
            imageBase64: Data(repeating: 0x61, count: 4 * 1_024 * 1_024).base64EncodedString(),
            recognizedText: "must reach the agent")
        let gate = CaptureGate(snapshot: shot)
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 5),
            capture: { await gate.capture() })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }
        let configuration = try host.start()
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        var descriptor = try UnixSocket.connect(path: ticket.socketPath)
        defer {
            if descriptor >= 0 {
                UnixSocket.closeConnection(descriptor)
            }
        }
        let request = MCPBridgeRequest(
            token: ticket.token,
            attemptID: ticket.attemptID,
            configurationRevision: ticket.configurationRevision,
            requestID: "undeliverable-capture",
            name: captureScreenTool.name,
            argumentsJSON: "{}")
        try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)

        await gate.waitUntilEntered()
        await gate.release()
        // Let the broker finish and the multi-megabyte reply fill the socket before resetting it.
        try await Task.sleep(for: .milliseconds(10))
        var reset = linger(l_onoff: 1, l_linger: 0)
        _ = withUnsafePointer(to: &reset) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_LINGER,
                $0,
                socklen_t(MemoryLayout<linger>.size))
        }
        UnixSocket.closeConnection(descriptor)
        descriptor = -1

        var wasInvalidated = false
        for _ in 0..<100 {
            do {
                _ = try await broker.requireTerminal()
            } catch let failure as CoachingActionBroker.Failure {
                if failure == .invalidated {
                    wasInvalidated = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(wasInvalidated)
    }

    @Test func socketPathsAreBoundedAndMessagesAreReadInChunks() async throws {
        let overlongPath = String(repeating: "x", count: UnixSocket.maximumPathBytes)
        #expect(throws: (any Error).self) {
            _ = try UnixSocket.connect(path: overlongPath)
        }
        #expect(throws: (any Error).self) {
            _ = try UnixSocket.makeListener(path: overlongPath)
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            UnixSocket.closeConnection(descriptors[0])
            UnixSocket.closeConnection(descriptors[1])
        }
        let writeDescriptor = descriptors[0]
        let readDescriptor = descriptors[1]
        let message = Data(repeating: 0x61, count: 2 * 1_024 * 1_024)
        let writer = Task.detached {
            try UnixSocket.writeMessage(message, to: writeDescriptor)
        }
        #expect(try UnixSocket.readMessage(from: readDescriptor) == message)
        try await writer.value
    }

    @Test func oneMCPProcessCanCaptureAndTerminate() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = ScreenSnapshot(
            imageBase64: Data("comparison-jpeg".utf8).base64EncodedString(),
            recognizedText: "comparison token")

        let mcpRuns = Counter()
        let mcpBase = CLIBrainClient(
            provider: .claudeCode,
            executable: URL(fileURLWithPath: "/fake/claude"),
            model: "comparison",
            workDirectory: directory,
            run: { invocation, _ in
                _ = mcpRuns.next()
                let configIndex = try #require(
                    invocation.arguments.firstIndex(of: "--mcp-config"))
                let configData = try Data(
                    contentsOf: URL(fileURLWithPath: invocation.arguments[configIndex + 1]))
                let config = try #require(
                    try JSONSerialization.jsonObject(with: configData) as? [String: Any])
                let servers = try #require(config["mcpServers"] as? [String: Any])
                let jarvis = try #require(servers["jarvis"] as? [String: Any])
                #expect(jarvis["alwaysLoad"] as? Bool == true)
                let arguments = try #require(jarvis["args"] as? [String])
                let ticket = try JSONDecoder().decode(
                    MCPBridgeTicket.self,
                    from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))

                _ = try Self.exchange(
                    MCPBridgeRequest(
                        token: ticket.token,
                        attemptID: ticket.attemptID,
                        configurationRevision: ticket.configurationRevision,
                        requestID: "capture",
                        name: captureScreenTool.name,
                        argumentsJSON: "{}"),
                    ticket: ticket)
                _ = try Self.exchange(
                    MCPBridgeRequest(
                        token: ticket.token,
                        attemptID: ticket.attemptID,
                        configurationRevision: ticket.configurationRevision,
                        requestID: "speak",
                        name: speakTool.name,
                        argumentsJSON: #"{"lines":["Use the comparison token."]}"#),
                    ticket: ticket)
                let envelope = #"{"type":"result","is_error":false,"result":""}"#
                return AgentCLIOutput(stdout: envelope, stderr: "", exitCode: 0)
            })
        let mcpBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { shot })
        let mcpClient = MCPBrainClient(
            base: mcpBase,
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
        let mcpResponse = try await mcpClient.respond(
            messages: [.user("Use the screen evidence.")],
            tools: coachTools,
            toolChoice: .required,
            actionBroker: mcpBroker)

        #expect(mcpRuns.value == 1)
        #expect(mcpResponse.actionDelivery == .broker)
        #expect(await mcpBroker.events().count == 2)
        #expect(try await mcpBroker.commit()
                == .speak(callID: "speak", lines: ["Use the comparison token."]))

    }

    @Test func cleanMCPExitWithoutATerminalIsRejected() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = CLIBrainClient(
            provider: .claudeCode,
            executable: URL(fileURLWithPath: "/fake/claude"),
            model: "comparison",
            workDirectory: directory,
            run: { _, _ in
                AgentCLIOutput(
                    stdout: #"{"type":"result","is_error":false,"result":"plain text only"}"#,
                    stderr: "",
                    exitCode: 0)
            })
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let client = MCPBrainClient(
            base: base,
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))

        do {
            _ = try await client.respond(
                messages: [.user("coach me")],
                tools: coachTools,
                toolChoice: .required,
                actionBroker: broker)
            Issue.record("plain MCP output was accepted as an action")
        } catch let failure as CoachingActionBroker.Failure {
            #expect(failure == .missingTerminal)
        }
    }

    @Test func longSessionPathUsesTheShortPrivateSocketDirectory() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let longDirectory = root.appendingPathComponent(String(repeating: "x", count: 100))
        try FileManager.default.createDirectory(
            at: longDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: longDirectory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }

        let configuration = try host.start()
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        #expect(!ticket.socketPath.hasPrefix(longDirectory.path))
        #expect(ticket.socketPath.utf8CString.count <= UnixSocket.maximumPathBytes)
        #expect(FileManager.default.fileExists(atPath: ticket.socketPath))
    }
}
