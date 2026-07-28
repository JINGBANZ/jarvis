import Foundation
import Logging
import MCP

/// Thin delivery hook around an official-SDK transport.
///
/// The wrapped transport still owns connection setup, MCP framing, and byte I/O. This actor only
/// confirms a broker action after a successful `tools/call` response write, and revokes the pending
/// action when the MCP client cancels or the transport closes/fails first.
actor MCPActionTrackingTransport<Base: Transport>: Transport {
    nonisolated let logger = Logger(
        label: "jarvis.mcp.action-delivery",
        factory: { _ in SwiftLogNoOpLogHandler() })

    private let base: Base
    private let deliveryTracker: MCPActionDeliveryTracker

    init(base: Base, deliveryTracker: MCPActionDeliveryTracker) {
        self.base = base
        self.deliveryTracker = deliveryTracker
    }

    func connect() async throws {
        try await base.connect()
    }

    func disconnect() async {
        await deliveryTracker.cancelPending()
        await base.disconnect()
    }

    func send(_ data: Data) async throws {
        do {
            try await base.send(data)
        } catch {
            await deliveryTracker.cancelPending()
            throw error
        }

        for _ in 0..<Self.successfulToolResultCount(in: data) {
            try await deliveryTracker.confirmPending()
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        let base = self.base
        let deliveryTracker = self.deliveryTracker
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    let stream = await base.receive()
                    for try await data in stream {
                        if Self.containsCancellationNotification(data) {
                            await deliveryTracker.cancelPending()
                        }
                        continuation.yield(data)
                    }
                    await deliveryTracker.cancelPending()
                    continuation.finish()
                } catch {
                    await deliveryTracker.cancelPending()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                Task { await deliveryTracker.cancelPending() }
            }
        }
    }

    private static func successfulToolResultCount(in data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        let messages = object as? [[String: Any]] ?? [object as? [String: Any]].compactMap { $0 }
        return messages.count { message in
            guard let result = message["result"] as? [String: Any],
                  result["content"] is [[String: Any]] else {
                return false
            }
            return result["isError"] as? Bool != true
        }
    }

    private static func containsCancellationNotification(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        let messages = object as? [[String: Any]] ?? [object as? [String: Any]].compactMap { $0 }
        return messages.contains {
            $0["method"] as? String == CancelledNotification.name
        }
    }
}
