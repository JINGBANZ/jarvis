import Foundation
import JarvisMCPBridge

/// Holds the one accepted Jarvis action whose MCP `tools/call` response has not yet crossed the
/// provider transport.
///
/// The broker rejects concurrent actions, so a single pending delivery is the complete state. A
/// cancellation, transport failure, or dropped tracker closes the private bridge connection; the
/// host then invalidates the attempt instead of retaining an action the provider never received.
actor MCPActionDeliveryTracker {
    enum Failure: Error {
        case concurrentAcceptedAction
    }

    private var pending: MCPBridgeClient.Delivery?

    deinit {
        pending?.cancel()
    }

    func register(_ delivery: MCPBridgeClient.Delivery) throws {
        guard pending == nil else {
            delivery.cancel()
            pending?.cancel()
            pending = nil
            throw Failure.concurrentAcceptedAction
        }
        pending = delivery
    }

    /// Called only after the SDK transport has written a successful `tools/call` response.
    func confirmPending() async throws {
        guard let delivery = pending else { return }
        // Removing first makes the successful transport send the atomic point of no return:
        // cancellation after this point cannot revoke an action already delivered to the CLI.
        pending = nil
        try await delivery.confirm()
    }

    func cancelPending() {
        let delivery = pending
        pending = nil
        delivery?.cancel()
    }
}
