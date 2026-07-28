import Foundation
import JarvisCore
import JarvisMCPBridge
@testable import JarvisMCPServerCore
import Logging
import MCP
import System
import Testing

@Suite(.serialized) struct JarvisMCPServerTests {
    private actor SendGate {
        private var armed = false
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func arm() {
            armed = true
        }

        func pauseIfArmed() async {
            guard armed else { return }
            armed = false
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { releaseWaiter = $0 }
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

    /// Test-only transport seam. The SDK still owns all message encoding and dispatch; this wrapper
    /// pauses one send to put cancellation exactly between handler return and transport delivery.
    private actor GatedSendTransport<Base: Transport>: Transport {
        nonisolated let logger = Logger(
            label: "jarvis.tests.gated-mcp-transport",
            factory: { _ in SwiftLogNoOpLogHandler() })

        private let base: Base
        private let gate: SendGate

        init(base: Base, gate: SendGate) {
            self.base = base
            self.gate = gate
        }

        func connect() async throws {
            try await base.connect()
        }

        func disconnect() async {
            await base.disconnect()
        }

        func send(_ data: Data) async throws {
            await gate.pauseIfArmed()
            try await base.send(data)
        }

        func receive() -> AsyncThrowingStream<Data, Error> {
            let base = self.base
            return AsyncThrowingStream { continuation in
                let reader = Task {
                    do {
                        let stream = await base.receive()
                        for try await data in stream {
                            continuation.yield(data)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in reader.cancel() }
            }
        }
    }

    private actor CaptureGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func capture() async -> ScreenSnapshot? {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { releaseWaiter = $0 }
            return nil
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
            .appendingPathComponent("jmcp-sdk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func connectedClient(
        ticketFile: URL
    ) async throws -> (Server, Client, Initialize.Result) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let bridge = try MCPBridgeClient(ticketFile: ticketFile)
        let deliveryTracker = MCPActionDeliveryTracker()
        let server = try await JarvisMCPServer.makeServer(
            bridge: bridge,
            deliveryTracker: deliveryTracker)
        let trackedServerTransport = MCPActionTrackingTransport(
            base: serverTransport,
            deliveryTracker: deliveryTracker)
        let client = Client(name: "JarvisTests", version: "1.0.0")
        try await server.start(transport: trackedServerTransport)
        let initialized = try await client.connect(transport: clientTransport)
        return (server, client, initialized)
    }

    private static func texts(in content: [Tool.Content]) -> [String] {
        content.compactMap {
            guard case .text(let text, _, _) = $0 else { return nil }
            return text
        }
    }

    private static func images(in content: [Tool.Content]) -> [(String, String)] {
        content.compactMap {
            guard case .image(let data, let mimeType, _, _) = $0 else { return nil }
            return (data, mimeType)
        }
    }

    @Test func officialSDKNegotiatesLifecycleAndRunsCaptureThenSpeak() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = ScreenSnapshot(
            imageBase64: Data("sdk-jpeg".utf8).base64EncodedString(),
            recognizedText: "official SDK evidence")
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 11),
            capture: { shot })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
        defer { host.close() }
        let attempt = try host.beginAttempt(provider: .codexCLI, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()
        defer {
            try? clientToServerRead.close()
            try? clientToServerWrite.close()
            try? serverToClientRead.close()
            try? serverToClientWrite.close()
        }
        let baseServerTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite)
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite)
        let bridge = try MCPBridgeClient(ticketFile: configuration.ticketFile)
        let deliveryTracker = MCPActionDeliveryTracker()
        let server = try await JarvisMCPServer.makeServer(
            bridge: bridge,
            deliveryTracker: deliveryTracker)
        let serverTransport = MCPActionTrackingTransport(
            base: baseServerTransport,
            deliveryTracker: deliveryTracker)
        let client = Client(name: "JarvisTests", version: "1.0.0")
        try await server.start(transport: serverTransport)
        let initialized = try await client.connect(transport: clientTransport)

        #expect(initialized.protocolVersion == Version.latest)
        #expect(initialized.serverInfo.name == "jarvis-actions")
        let listed = try await client.listTools()
        #expect(listed.tools.map(\.name)
                == ["capture_screen", "speak", "stay_silent"])
        #expect(listed.tools.allSatisfy { $0.inputSchema.objectValue != nil })

        let capture = try await client.callTool(
            name: captureScreenTool.name,
            arguments: [:])
        #expect(Self.texts(in: capture.content).contains {
            $0.contains("official SDK evidence")
        })
        #expect(Self.images(in: capture.content).contains {
            $0 == (shot.imageBase64, "image/jpeg")
        })

        let terminal = try await client.callTool(
            name: speakTool.name,
            arguments: ["lines": ["Trust the SDK evidence."]])
        #expect(terminal.isError != true)
        let committed = try await broker.commit()
        if case .speak(_, let lines) = committed {
            #expect(lines == ["Trust the SDK evidence."])
        } else {
            Issue.record("SDK terminal call did not stage speak")
        }

        await client.disconnect()
        await server.stop()
    }

    @Test func officialSDKRunsStaySilentAsATerminalAction() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 14),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
        defer { host.close() }
        let attempt = try host.beginAttempt(provider: .codexCLI, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
        let (server, client, _) = try await Self.connectedClient(
            ticketFile: configuration.ticketFile)

        let result = try await client.callTool(
            name: staySilentTool.name,
            arguments: [:])
        #expect(result.isError != true)
        let committed = try await broker.commit()
        guard case .staySilent(_) = committed else {
            Issue.record("SDK terminal call did not stage stay_silent")
            await client.disconnect()
            await server.stop()
            return
        }

        await client.disconnect()
        await server.stop()
    }

    @Test func officialSDKPreservesConcurrentToolCallsForBrokerRejection() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CaptureGate()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 12),
            capture: { await gate.capture() })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
        defer { host.close() }
        let attempt = try host.beginAttempt(provider: .codexCLI, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
        let (server, client, _) = try await Self.connectedClient(
            ticketFile: configuration.ticketFile)

        let capture = Task {
            try await client.callTool(name: captureScreenTool.name, arguments: [:])
        }
        await gate.waitUntilEntered()
        let terminal = try await client.callTool(
            name: speakTool.name,
            arguments: ["lines": ["This raced the screenshot."]])
        #expect(terminal.isError == true)

        await gate.release()
        #expect(try await capture.value.isError == true)
        do {
            _ = try await broker.requireTerminal()
            Issue.record("pipelined SDK calls left a valid terminal")
        } catch let failure as CoachingActionBroker.Failure {
            #expect(failure == .concurrentCall)
        }

        await client.disconnect()
        await server.stop()
    }

    @Test func officialSDKCancellationInvalidatesTheBrokerAttempt() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CaptureGate()
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 13),
            capture: { await gate.capture() })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
        defer { host.close() }
        let attempt = try host.beginAttempt(provider: .codexCLI, broker: broker)
        defer { host.endAttempt(attempt) }
        let configuration = attempt.configuration
        let (server, client, _) = try await Self.connectedClient(
            ticketFile: configuration.ticketFile)

        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: captureScreenTool.name,
            arguments: [:])
        await gate.waitUntilEntered()
        try await client.cancelRequest(context.requestID, reason: "test cancellation")
        do {
            _ = try await context.value
            Issue.record("cancelled SDK tool call returned a result")
        } catch is CancellationError {
            // Expected: the SDK consumed the cancellation and suppressed the response.
        }

        try await Task.sleep(for: .milliseconds(100))
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await broker.requireTerminal()
            Issue.record("cancelled SDK tool call left the broker attempt active")
        } catch let failure as CoachingActionBroker.Failure {
            #expect(failure == .invalidated)
        }
        #expect(await broker.captureObservation() == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test func cancellationBeforeToolResponseDeliveryInvalidatesTheBrokerAttempt() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = CoachingActionBroker(
            identity: .init(configurationRevision: 15),
            capture: { nil })
        let host = MCPBridgeHost(
            sessionDirectory: directory,
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"))
        defer { host.close() }
        let attempt = try host.beginAttempt(provider: .codexCLI, broker: broker)
        defer { host.endAttempt(attempt) }

        let (clientTransport, baseServerTransport) =
            await InMemoryTransport.createConnectedPair()
        let gate = SendGate()
        let deliveryTracker = MCPActionDeliveryTracker()
        let bridge = try MCPBridgeClient(ticketFile: attempt.configuration.ticketFile)
        let server = try await JarvisMCPServer.makeServer(
            bridge: bridge,
            deliveryTracker: deliveryTracker)
        let gatedServerTransport = GatedSendTransport(
            base: baseServerTransport,
            gate: gate)
        let serverTransport = MCPActionTrackingTransport(
            base: gatedServerTransport,
            deliveryTracker: deliveryTracker)
        let client = Client(name: "JarvisTests", version: "1.0.0")
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        await gate.arm()
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: speakTool.name,
            arguments: ["lines": ["This response has not crossed MCP yet."]])
        await gate.waitUntilEntered()
        try await client.cancelRequest(
            context.requestID,
            reason: "cancel before transport delivery")

        // Keep the response write paused until the server has consumed the cancellation. This
        // proves revocation happens at the MCP boundary, not because a later send happened to fail.
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
        await gate.release()
        #expect(wasInvalidated)

        do {
            _ = try await context.value
            Issue.record("cancelled SDK tool call returned a result")
        } catch is CancellationError {
            // Expected: the SDK discarded the response before the gated transport delivered it.
        }

        await client.disconnect()
        await server.stop()
    }
}
