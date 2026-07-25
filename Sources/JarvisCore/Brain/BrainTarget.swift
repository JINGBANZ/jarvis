import Foundation

/// One destination in a coaching route. The model id is interpreted within `provider`'s catalog,
/// so two targets may deliberately use the same provider with different models.
public struct BrainTarget: Sendable, Hashable {
    public let provider: BrainProvider
    public let modelID: String

    public init(provider: BrainProvider, modelID: String) {
        self.provider = provider
        self.modelID = modelID
    }

    /// The current catalog entry, or nil when a persisted target refers to a model that no longer
    /// exists. Route normalization drops unknown fallback targets rather than sending them.
    public var model: BrainModel? {
        BrainModelCatalog.model(id: modelID, for: provider)
    }
}
