import Foundation

/// Runtime-ready route plus typed provider-level transition callbacks.
///
/// Raw provider errors never enter these callbacks: each transition carries the classified
/// `ProviderFailure` that caused it, and the raw text stays in `jarvis-debug.log`. The App edge
/// uses target identity plus that record to write Activity copy or stop after route exhaustion.
public struct ConfiguredBrainRoute: Sendable {
    let targets: [ConfiguredBrainTarget]
    let onSelected: (@MainActor @Sendable (BrainTarget) -> Void)?
    let onAdvanced: (@MainActor @Sendable (BrainTarget, BrainTarget, ProviderFailure) -> Void)?
    let onSkipped: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)?
    let onRecoveryChanged: (@MainActor @Sendable (BrainProvider?) -> Void)?
    let onExhausted: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)?
    /// Every configured target is permanently unavailable; carries the last target proven so.
    let onTerminated: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)?
    /// A failure streak reached `BrainCycleRecovery.ceiling` without a success; carries the most
    /// recent cycle's failure.
    let onRecoveryExpired: (@MainActor @Sendable (ProviderFailure) -> Void)?

    public init(
        targets: [ConfiguredBrainTarget],
        onSelected: (@MainActor @Sendable (BrainTarget) -> Void)? = nil,
        onAdvanced: (@MainActor @Sendable (BrainTarget, BrainTarget, ProviderFailure) -> Void)? = nil,
        onSkipped: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)? = nil,
        onRecoveryChanged: (@MainActor @Sendable (BrainProvider?) -> Void)? = nil,
        onExhausted: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)? = nil,
        onTerminated: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)? = nil,
        onRecoveryExpired: (@MainActor @Sendable (ProviderFailure) -> Void)? = nil
    ) {
        precondition(!targets.isEmpty, "a configured brain route needs a primary target")
        self.targets = targets
        self.onSelected = onSelected
        self.onAdvanced = onAdvanced
        self.onSkipped = onSkipped
        self.onExhausted = onExhausted
        self.onTerminated = onTerminated
        self.onRecoveryExpired = onRecoveryExpired
        self.onRecoveryChanged = onRecoveryChanged
    }
}
