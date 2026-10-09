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

    public func credentialFailure(available: Set<Credential>) -> ProviderFailure? {
        guard let credential = provider.credential, !available.contains(credential) else { return nil }
        return ProviderFailure(
            source: .brain(provider), stage: .process, category: .authentication,
            disposition: .permanent, identity: .init(),
            message: "No \(credential.displayName) is saved. Add it in Settings → Connections.")
    }
}
