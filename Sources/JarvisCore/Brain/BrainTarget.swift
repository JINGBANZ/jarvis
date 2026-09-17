import Foundation

public struct BrainTarget: Sendable, Hashable {
    public let provider: BrainProvider
    public let modelID: String

    public init(provider: BrainProvider, modelID: String) {
        self.provider = provider
        self.modelID = modelID
    }

    /// Nil when a persisted model id is no longer in the catalog.
    public var model: BrainModel? {
        BrainModelCatalog.model(id: modelID, for: provider)
    }
}
