import Foundation

/// Runtime-ready route plus typed provider-level transition callbacks.
///
/// Raw provider errors never enter these callbacks; they stay in `jarvis-debug.log`. The App edge
/// uses only target identity to write fixed Activity copy or stop after final route exhaustion.
public struct ConfiguredBrainRoute: Sendable {
    let targets: [ConfiguredBrainTarget]
    let onSelected: (@MainActor @Sendable (BrainTarget) -> Void)?
    let onAdvanced: (@MainActor @Sendable (BrainTarget, BrainTarget) -> Void)?
    let onSkipped: (@MainActor @Sendable (BrainTarget) -> Void)?
    let onExhausted: (@MainActor @Sendable (BrainTarget, BrainFailure) -> Void)?

    public init(
        targets: [ConfiguredBrainTarget],
        onSelected: (@MainActor @Sendable (BrainTarget) -> Void)? = nil,
        onAdvanced: (@MainActor @Sendable (BrainTarget, BrainTarget) -> Void)? = nil,
        onSkipped: (@MainActor @Sendable (BrainTarget) -> Void)? = nil,
        onExhausted: (@MainActor @Sendable (BrainTarget, BrainFailure) -> Void)? = nil
    ) {
        precondition(!targets.isEmpty, "a configured brain route needs a primary target")
        self.targets = targets
        self.onSelected = onSelected
        self.onAdvanced = onAdvanced
        self.onSkipped = onSkipped
        self.onExhausted = onExhausted
    }
}
