import Foundation

/// One bundled coaching skill: guidance for a kind of interview question, loaded on demand.
///
/// `description` is the only part the model reads before deciding: it names the kind of question
/// the skill helps with, with an example, and it is what the prompt's catalog line carries.
/// `body` is the full guidance `load_skill` hands back as a tool result.
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
