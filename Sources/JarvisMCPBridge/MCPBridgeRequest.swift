import Foundation

struct MCPBridgeRequest: Codable, Sendable {
    let token: String
    let attemptID: UUID
    let configurationRevision: UInt
    let requestID: String
    let name: String
    let argumentsJSON: String
}
