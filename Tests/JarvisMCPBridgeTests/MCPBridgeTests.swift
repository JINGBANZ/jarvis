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

    private static func makeHost(directory: URL) -> MCPBridgeHost {
        MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
    }

    private static func beginAttempt(
        _ host: MCPBridgeHost,
        provider: BrainProvider = .codexCLI,
        broker: CoachingActionBroker
    ) throws -> MCPBridgeHost.Attempt {
        try host.beginAttempt(provider: provider, broker: broker)
    }

    private static func exchange(
        _ request: MCPBridgeRequest,
        ticket: MCPBridgeTicket
    ) throws -> MCPBridgeResponse {
        let descriptor = try UnixSocket.connect(path: ticket.socketPath)
        defer { UnixSocket.closeConnection(descriptor) }
        try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)
        let response = try JSONDecoder().decode(
            MCPBridgeResponse.self,
            from: UnixSocket.readMessage(from: descriptor))
        if response.ok {
            let acknowledgement = MCPBridgeAcknowledgement(requestID: request.requestID)
            try UnixSocket.writeMessage(
                try JSONEncoder().encode(acknowledgement),
                to: descriptor)
            #expect(try JSONDecoder().decode(
                MCPBridgeAcknowledgement.self,
                from: UnixSocket.readMessage(from: descriptor)) == acknowledgement)
        }
        return response
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
        let host = Self.makeHost(directory: directory)

        #expect(throws: (any Error).self) {
            _ = try Self.beginAttempt(host, broker: broker)
        }
    }

    @Test func authenticatedSocketForwardsActionsAndSeparatesAttemptFromSessionCleanup() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = ScreenSnapshot(
            imageBase64: Data("synthetic-jpeg".utf8).base64EncodedString(),
            recognizedText: "synthetic screen")
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 9),
            capture: { shot })
        let host = Self.makeHost(directory: directory)
        let attempt = try Self.beginAttempt(host, provider: .claudeCode, broker: broker)
        let configuration = attempt.configuration
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
        #expect(attempt.completionSignal.reason == nil)

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
        #expect(attempt.completionSignal.reason == .terminalActionDelivered)
        #expect(try await broker.commit()
                == .speak(callID: "speak", lines: ["Use the synthetic evidence."]))

        let claudeConfigFile = try #require(configuration.claudeConfigFile)
        let socketFile = URL(fileURLWithPath: ticket.socketPath)
        host.endAttempt(attempt)
        #expect(FileManager.default.fileExists(atPath: socketFile.path))
        #expect(!FileManager.default.fileExists(atPath: configuration.ticketFile.path))
        #expect(!FileManager.default.fileExists(atPath: claudeConfigFile.path))

        host.close()
        #expect([socketFile, configuration.ticketFile, claudeConfigFile].allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test func sequentialAttemptsReuseTheSessionTransportButRotateAuthorization() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.makeHost(directory: directory)
        defer { host.close() }

        let firstBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let firstAttempt = try Self.beginAttempt(
            host,
            provider: .claudeCode,
            broker: firstBroker)
        let firstConfiguration = firstAttempt.configuration
        let firstTicket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: firstConfiguration.ticketFile))
        let listener = try #require(Self.listenerDescriptor(path: firstTicket.socketPath))
        host.endAttempt(firstAttempt)
        #expect(firstAttempt.completionSignal.reason == nil)

        let secondBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 2),
            capture: { nil })
        let secondAttempt = try Self.beginAttempt(
            host,
            provider: .claudeCode,
            broker: secondBroker)
        defer { host.endAttempt(secondAttempt) }
        let secondConfiguration = secondAttempt.configuration
        let secondTicket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: secondConfiguration.ticketFile))

        #expect(secondTicket.socketPath == firstTicket.socketPath)
        #expect(secondConfiguration.ticketFile != firstConfiguration.ticketFile)
        #expect(secondConfiguration.claudeConfigFile != firstConfiguration.claudeConfigFile)
        #expect(Self.listenerDescriptor(path: secondTicket.socketPath) == listener)
        #expect(secondTicket.token != firstTicket.token)
        #expect(secondTicket.attemptID != firstTicket.attemptID)
        #expect(secondTicket.configurationRevision == 2)
        #expect(!FileManager.default.fileExists(atPath: firstConfiguration.ticketFile.path))
        #expect(!FileManager.default.fileExists(
            atPath: try #require(firstConfiguration.claudeConfigFile).path))
        #expect(FileManager.default.fileExists(atPath: secondConfiguration.ticketFile.path))
        #expect(FileManager.default.fileExists(
            atPath: try #require(secondConfiguration.claudeConfigFile).path))

        // This models an orphaned helper that already decoded the previous ticket before rotation.
        let stale = try Self.exchange(
            MCPBridgeRequest(
                token: firstTicket.token,
                attemptID: firstTicket.attemptID,
                configurationRevision: firstTicket.configurationRevision,
                requestID: "stale-speak",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["This belongs to the old attempt."]}"#),
            ticket: firstTicket)
        #expect(!stale.ok)
        #expect(secondAttempt.completionSignal.reason == nil)

        let current = try Self.exchange(
            MCPBridgeRequest(
                token: secondTicket.token,
                attemptID: secondTicket.attemptID,
                configurationRevision: secondTicket.configurationRevision,
                requestID: "current-speak",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["This belongs to the new attempt."]}"#),
            ticket: secondTicket)
        #expect(current.ok)
        #expect(secondAttempt.completionSignal.reason == .terminalActionDelivered)
        #expect(try await secondBroker.commit()
                == .speak(callID: "current-speak", lines: ["This belongs to the new attempt."]))
        do {
            _ = try await firstBroker.requireTerminal()
            Issue.record("the new attempt reached the old broker")
        } catch let failure as CoachingActionBroker.Failure {
            #expect(failure == .missingTerminal)
        }
    }

    @Test func attemptHandleCannotEndAnotherSessionHostLease() async throws {
        let firstDirectory = try Self.makeDirectory()
        let secondDirectory = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let firstHost = Self.makeHost(directory: firstDirectory)
        let secondHost = Self.makeHost(directory: secondDirectory)
        defer {
            firstHost.close()
            secondHost.close()
        }
        let firstBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let secondBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let firstAttempt = try Self.beginAttempt(firstHost, broker: firstBroker)
        let secondAttempt = try Self.beginAttempt(secondHost, broker: secondBroker)
        defer {
            firstHost.endAttempt(firstAttempt)
            secondHost.endAttempt(secondAttempt)
        }

        // Both are generation one, so the opaque host binding—not the counter alone—must reject it.
        secondHost.endAttempt(firstAttempt)
        #expect(FileManager.default.fileExists(
            atPath: secondAttempt.configuration.ticketFile.path))
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: secondAttempt.configuration.ticketFile))
        let response = try Self.exchange(
            MCPBridgeRequest(
                token: ticket.token,
                attemptID: ticket.attemptID,
                configurationRevision: ticket.configurationRevision,
                requestID: "second-host-speak",
                name: speakTool.name,
                argumentsJSON: #"{"lines":["The second host remains active."]}"#),
            ticket: ticket)
        #expect(response.ok)
        #expect(try await secondBroker.commit()
                == .speak(
                    callID: "second-host-speak",
                    lines: ["The second host remains active."]))
    }

    @Test func codexBridgeDoesNotCreateAClaudeConfiguration() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 10),
            capture: { nil })
        let host = Self.makeHost(directory: directory)
        defer { host.close() }

        let attempt = try Self.beginAttempt(host, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration

        #expect(configuration.claudeConfigFile == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == [configuration.ticketFile.lastPathComponent])
    }

    @Test func wrongBearerTokenCannotReachTheBroker() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 2),
            capture: { nil })
        let host = Self.makeHost(directory: directory)
        defer { host.close() }
        let attempt = try Self.beginAttempt(host, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
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

    @Test func closingSessionHostUnblocksAnActiveSidecarConnection() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 3),
            capture: { nil })
        let host = Self.makeHost(directory: directory)
        let attempt = try Self.beginAttempt(host, broker: broker)
        let configuration = attempt.configuration
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
        let host = Self.makeHost(directory: directory)
        let attempt = try Self.beginAttempt(host, broker: broker)
        let configuration = attempt.configuration
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

    @Test func endingAttemptCancelsAnInFlightBrokerCallButKeepsTheListener() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CaptureGate()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 4),
            capture: { await gate.capture() })
        let host = Self.makeHost(directory: directory)
        defer { host.close() }
        let attempt = try Self.beginAttempt(host, broker: broker)
        let configuration = attempt.configuration
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
        host.endAttempt(attempt)
        for _ in 0..<50 where completed.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.value == 1)

        await gate.release()
        _ = await exchange.value

        let nextBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 5),
            capture: { nil })
        let nextAttempt = try Self.beginAttempt(host, broker: nextBroker)
        defer { host.endAttempt(nextAttempt) }
        let nextTicket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: nextAttempt.configuration.ticketFile))
        #expect(nextTicket.socketPath == ticket.socketPath)
    }

    @Test func undeliverableCaptureReplyInvalidatesTheAttempt() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = ScreenSnapshot(
            imageBase64: Data(repeating: 0x61, count: 4 * 1_024 * 1_024).base64EncodedString(),
            recognizedText: "must reach the agent")
        let gate = CaptureGate(snapshot: shot)
        let observed = Counter()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 5),
            capture: { await gate.capture() },
            captureObserver: { _ in _ = observed.next() })
        let host = Self.makeHost(directory: directory)
        defer { host.close() }
        let attempt = try Self.beginAttempt(host, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
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
        #expect(attempt.completionSignal.reason == nil)
        #expect(observed.value == 0)
        #expect(await broker.captureObservation() == nil)
    }

    @Test func unacknowledgedTerminalReplyInvalidatesTheAttempt() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 6),
            capture: { nil })
        let host = Self.makeHost(directory: directory)
        defer { host.close() }
        let attempt = try Self.beginAttempt(host, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        let descriptor = try UnixSocket.connect(path: ticket.socketPath)
        let request = MCPBridgeRequest(
            token: ticket.token,
            attemptID: ticket.attemptID,
            configurationRevision: ticket.configurationRevision,
            requestID: "discarded-terminal",
            name: speakTool.name,
            argumentsJSON: #"{"lines":["This must not survive cancellation."]}"#)
        try UnixSocket.writeMessage(try JSONEncoder().encode(request), to: descriptor)
        let response = try JSONDecoder().decode(
            MCPBridgeResponse.self,
            from: UnixSocket.readMessage(from: descriptor))
        #expect(response.ok)
        UnixSocket.closeConnection(descriptor)

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
        #expect(attempt.completionSignal.reason == nil)
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

    @Test func socketDescriptorsCloseAcrossExec() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("close-on-exec.sock").path

        let listener = try UnixSocket.makeListener(path: socketPath)
        defer { UnixSocket.closeConnection(listener) }
        let client = try UnixSocket.connect(path: socketPath)
        defer { UnixSocket.closeConnection(client) }
        let accepted = try UnixSocket.acceptConnection(from: listener)
        defer { UnixSocket.closeConnection(accepted) }

        let descriptors = [listener, client, accepted]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC == FD_CLOEXEC)
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        let descriptorList = descriptors.map(String.init).joined(separator: " ")
        child.arguments = [
            "-c",
            "for descriptor in \(descriptorList); do "
                + "if test -S /dev/fd/$descriptor; then exit 42; fi; "
                + "done",
        ]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()

        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 0)
    }

    @Test func acknowledgedClaudeTerminalStopsAfterCaptureAndStillCommits() async throws {
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
                #expect(invocation.completionSignal?.reason == .terminalActionDelivered)
                #expect(invocation.completionEvidence == .stdoutJSONToolResult(
                    toolNames: [
                        "mcp__jarvis__speak",
                        "mcp__jarvis__stay_silent",
                    ],
                    acceptedText: terminalActionAcceptedText))
                return AgentCLIOutput(
                    stdout: "partial claude stream before final prose",
                    stderr: "",
                    exitCode: 15,
                    termination: .completionSignal(.terminalActionDelivered))
            })
        let mcpBroker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { shot })
        let bridge = Self.makeHost(directory: directory)
        defer { bridge.close() }
        let mcpClient = MCPBrainClient(
            base: mcpBase,
            bridge: bridge)
        let mcpResponse = try await mcpClient.respond(
            messages: [.user("Use the screen evidence.")],
            tools: coachTools,
            toolChoice: .required,
            actionBroker: mcpBroker)

        #expect(mcpRuns.value == 1)
        #expect(mcpResponse.actionDelivery == .broker)
        #expect(mcpResponse.outputText == nil)
        #expect(await mcpBroker.captureObservation()?.snapshot == shot)
        #expect(try await mcpBroker.commit()
                == .speak(callID: "speak", lines: ["Use the comparison token."]))

    }

    @Test func acknowledgedCodexTerminalStopsBeforeAReplyFileAndStillCommits() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = CLIBrainClient(
            provider: .codexCLI,
            executable: URL(fileURLWithPath: "/fake/codex"),
            model: "comparison",
            workDirectory: directory,
            run: { invocation, timings in
                let assignment = try #require(invocation.arguments.first {
                    $0.hasPrefix(#"mcp_servers.jarvis.args=["--ticket",""#)
                })
                let prefix = #"mcp_servers.jarvis.args=["--ticket",""#
                let suffix = "\"]"
                #expect(assignment.hasSuffix(suffix))
                let path = String(
                    assignment.dropFirst(prefix.count).dropLast(suffix.count))
                let ticket = try JSONDecoder().decode(
                    MCPBridgeTicket.self,
                    from: Data(contentsOf: URL(fileURLWithPath: path)))

                timings.mark(.runnerEntered)
                timings.mark(.processLaunched)
                _ = try Self.exchange(
                    MCPBridgeRequest(
                        token: ticket.token,
                        attemptID: ticket.attemptID,
                        configurationRevision: ticket.configurationRevision,
                        requestID: "codex-speak",
                        name: speakTool.name,
                        argumentsJSON: #"{"lines":["Stop at the acknowledged action."]}"#),
                    ticket: ticket)
                #expect(invocation.completionSignal?.reason == .terminalActionDelivered)
                #expect(invocation.completionEvidence == .signal)
                timings.mark(.processExited)
                return AgentCLIOutput(
                    stdout: "partial codex diagnostics",
                    stderr: "",
                    exitCode: 15,
                    termination: .completionSignal(.terminalActionDelivered))
            })
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let bridge = Self.makeHost(directory: directory)
        defer { bridge.close() }
        let client = MCPBrainClient(base: base, bridge: bridge)

        let response = try await client.respond(
            messages: [.user("coach me")],
            tools: [speakTool],
            toolChoice: .force(speakTool.name),
            actionBroker: broker)

        #expect(response.actionDelivery == .broker)
        #expect(response.outputText == nil)
        #expect(try await broker.commit() == .speak(
            callID: "codex-speak",
            lines: ["Stop at the acknowledged action."]))
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
        let bridge = Self.makeHost(directory: directory)
        defer { bridge.close() }
        let client = MCPBrainClient(
            base: base,
            bridge: bridge)

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
        let host = Self.makeHost(directory: longDirectory)
        defer { host.close() }

        let attempt = try Self.beginAttempt(host, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
        let ticket = try JSONDecoder().decode(
            MCPBridgeTicket.self,
            from: Data(contentsOf: configuration.ticketFile))
        #expect(!ticket.socketPath.hasPrefix(longDirectory.path))
        #expect(ticket.socketPath.utf8CString.count <= UnixSocket.maximumPathBytes)
        #expect(FileManager.default.fileExists(atPath: ticket.socketPath))
    }
}
