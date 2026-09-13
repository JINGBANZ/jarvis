import Foundation

/// One runtime-ready entry in the user's ordered brain route.
///
/// `brain == nil` represents a target that was proven unavailable while the app assembled the
/// route (for example, a missing or signed-out CLI). The session skips it without manufacturing
/// provider attempts against the failure budget. Keeping the unavailable entry in the runtime route
/// preserves ordering and lets the driver emit one fixed, typed transition when the cursor reaches it.
public struct ConfiguredBrainTarget: Sendable {
    public let target: BrainTarget
    let brain: BrainClient?
    let summarizer: BrainClient?
    /// Set when the app proved the target unavailable while assembling the route (a missing or
    /// signed-out CLI). Carried into the skip and exhaustion notices so Activity names the reason.
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
