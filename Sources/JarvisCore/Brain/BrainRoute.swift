import Foundation

/// A primary brain target followed by the user's ordered fallback targets.
///
/// Construction normalizes untrusted preference input: an unknown primary model becomes that
/// provider's default, while unknown fallback models and exact duplicate targets are omitted.
/// Provider repetition is otherwise valid because model ids are part of target identity.
public struct BrainRoute: Sendable, Equatable {
    public let primary: BrainTarget
    public let fallbackTargets: [BrainTarget]

    public init(primary: BrainTarget, fallbackTargets: [BrainTarget]) {
        self.primary = primary.model == nil
            ? BrainTarget(
                provider: primary.provider,
                modelID: BrainModelCatalog.defaultModel(for: primary.provider).id)
            : primary

        var seen = Set([self.primary])
        self.fallbackTargets = fallbackTargets.filter { target in
            guard target.model != nil else { return false }
            return seen.insert(target).inserted
        }
    }

    public var targets: [BrainTarget] {
        [primary] + fallbackTargets
    }
}
