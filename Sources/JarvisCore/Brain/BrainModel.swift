import Foundation

public struct BrainModel: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// The client sends the higher of this and the provider's floor.
    public let reasoningEffortFloor: ReasoningEffort?

    public init(id: String, displayName: String, reasoningEffortFloor: ReasoningEffort? = nil) {
        self.id = id
        self.displayName = displayName
        self.reasoningEffortFloor = reasoningEffortFloor
    }
}
