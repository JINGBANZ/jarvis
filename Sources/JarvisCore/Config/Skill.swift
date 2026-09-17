import Foundation

public struct Skill: Sendable, Equatable {
    public let name: String
    public let description: String
    public let body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }
}
