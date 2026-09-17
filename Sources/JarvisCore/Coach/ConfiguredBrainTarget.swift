import Foundation

/// An unavailable target stays in the route to keep its order, and is skipped without spending the
/// failure budget.
public struct ConfiguredBrainTarget: Sendable {
    public let target: BrainTarget
    let brain: BrainClient?
    let summarizer: BrainClient?
    let unavailability: ProviderFailure?

    public init(
        target: BrainTarget,
        brain: BrainClient,
        summarizer: BrainClient? = nil
    ) {
        self.target = target
        self.brain = brain
        self.summarizer = summarizer
        self.unavailability = nil
    }

    public init(unavailable target: BrainTarget, failure: ProviderFailure) {
        self.target = target
        self.brain = nil
        self.summarizer = nil
        self.unavailability = failure
    }

    func prepare() {
        brain?.prepare()
    }

}
