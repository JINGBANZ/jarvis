import Foundation

/// Normalizes untrusted preference input: an unknown primary model becomes the provider default,
/// and unknown or duplicate fallback targets are dropped.
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
