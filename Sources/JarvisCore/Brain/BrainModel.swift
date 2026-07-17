import Foundation

/// One selectable brain (LLM) model: its API id and the label shown in Settings. The curated lists
/// live in `BrainModelCatalog`.
public struct BrainModel: Sendable, Equatable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
