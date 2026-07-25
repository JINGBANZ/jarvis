import Foundation

/// A user-selected provider that may take over an established coaching conversation after the
/// active provider exhausts its immediate retries for a temporary failure. The clients and failure
/// policy move together; the callbacks carry only provider identities so App-facing Activity copy
/// stays fixed while raw failure detail remains in diagnostics.
public struct ConfiguredBrainFallback: Sendable {
    let brain: BrainClient
    let provider: BrainProvider
    let summarizer: BrainClient?
    let onFailure: (@MainActor @Sendable (BrainFailure) -> Void)?
    let onActivated: (@Sendable (BrainProvider?, BrainProvider) -> Void)?
    let onPrimaryRecovered: (@Sendable (BrainProvider?, BrainProvider) -> Void)?
    let onRecoveryDeferred: (@Sendable (BrainProvider?, BrainProvider) -> Void)?
    let onUnavailable: (@Sendable (BrainProvider?, BrainProvider) -> Void)?

    public init(
        brain: BrainClient,
        provider: BrainProvider,
        summarizer: BrainClient? = nil,
        onFailure: (@MainActor @Sendable (BrainFailure) -> Void)? = nil,
        onActivated: (@Sendable (BrainProvider?, BrainProvider) -> Void)? = nil,
        onPrimaryRecovered: (@Sendable (BrainProvider?, BrainProvider) -> Void)? = nil,
        onRecoveryDeferred: (@Sendable (BrainProvider?, BrainProvider) -> Void)? = nil,
        onUnavailable: (@Sendable (BrainProvider?, BrainProvider) -> Void)? = nil
    ) {
        self.brain = brain
        self.provider = provider
        self.summarizer = summarizer
        self.onFailure = onFailure
        self.onActivated = onActivated
        self.onPrimaryRecovered = onPrimaryRecovered
        self.onRecoveryDeferred = onRecoveryDeferred
        self.onUnavailable = onUnavailable
    }
}
