import Foundation
import JarvisCore
import JarvisMCPBridge
@testable import JarvisMCPServerCore
import MCP
import System
import Testing

@Suite(.serialized) struct JarvisMCPServerTests {
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
        let server = try await JarvisMCPServer.makeServer(bridge: bridge)
        let client = Client(name: "JarvisTests", version: "1.0.0")
        try await server.start(transport: serverTransport)
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
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }
        let configuration = try host.start()
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()
        defer {
            try? clientToServerRead.close()
            try? clientToServerWrite.close()
            try? serverToClientRead.close()
            try? serverToClientWrite.close()
        }
        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite)
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite)
        let bridge = try MCPBridgeClient(ticketFile: configuration.ticketFile)
        let server = try await JarvisMCPServer.makeServer(bridge: bridge)
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
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }
        let configuration = try host.start()
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
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }
        let configuration = try host.start()
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
            serverExecutable: URL(fileURLWithPath: "/fake/JarvisMCPServer"),
            broker: broker)
        defer { host.close() }
        let configuration = try host.start()
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
        #expect(await broker.events().isEmpty)

        await client.disconnect()
        await server.stop()
    }
}
