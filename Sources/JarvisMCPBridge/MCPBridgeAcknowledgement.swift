import Foundation

/// Sidecar proof that a successful action result survived its final cancellation check.
struct MCPBridgeAcknowledgement: Codable, Sendable, Equatable {
    let requestID: String
}
