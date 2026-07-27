import Foundation
import Testing
@testable import JarvisCore
@testable import JarvisMCPBridge

@Suite(.serialized) struct MCPBridgeTests {
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

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("jmcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func exchange(
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

    @Test func discoveryExposesExactlyTheThreeCoachingActions() throws {
        let tools = try MCPStdioServer.toolDescriptors()
        #expect(tools.compactMap { $0["name"] as? String }
            == ["capture_screen", "speak", "stay_silent"])
    }

    @Test func bridgeRejectsALooseSessionDirectory() throws {
        let directory = try makeDirectory()
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
        let directory = try makeDirectory()
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

        let capture = try exchange(
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

        let terminal = try exchange(
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
        let directory = try makeDirectory()
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
        let response = try exchange(
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
        let directory = try makeDirectory()
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

    @Test func oneMCPProcessCanCaptureAndTerminate() async throws {
        let directory = try makeDirectory()
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

                _ = try exchange(
                    MCPBridgeRequest(
                        token: ticket.token,
                        attemptID: ticket.attemptID,
                        configurationRevision: ticket.configurationRevision,
                        requestID: "capture",
                        name: captureScreenTool.name,
                        argumentsJSON: "{}"),
                    ticket: ticket)
                _ = try exchange(
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
        let directory = try makeDirectory()
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

    @Test func bridgeBootstrapFailureStopsBeforeProviderRun() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let longDirectory = root.appendingPathComponent(String(repeating: "x", count: 100))
        try FileManager.default.createDirectory(
            at: longDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let runs = Counter()
        let base = CLIBrainClient(
            provider: .claudeCode,
            executable: URL(fileURLWithPath: "/fake/claude"),
            model: "comparison",
            workDirectory: longDirectory,
            run: { _, _ in
                _ = runs.next()
                return AgentCLIOutput(
                    stdout: #"{"type":"result","is_error":false,"result":""}"#,
                    stderr: "",
                    exitCode: 0)
            })
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 1),
            capture: { nil })
        let client = MCPBrainClient(
            base: base,
            sessionDirectory: longDirectory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))

        do {
            _ = try await client.respond(
                messages: [.user("coach me")],
                tools: coachTools,
                toolChoice: .required,
                actionBroker: broker)
            Issue.record("bridge bootstrap failure was accepted")
        } catch let failure as BrainFailure {
            #expect(failure.disposition == .temporary)
            #expect(failure.detail.contains("private MCP bridge unavailable"))
        }
        #expect(runs.value == 0)
    }
}
