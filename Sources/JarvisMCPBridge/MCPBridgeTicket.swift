import Foundation

struct MCPBridgeTicket: Codable, Sendable, Equatable {
    let socketPath: String
    let token: String
    let attemptID: UUID
    let configurationRevision: UInt
}
