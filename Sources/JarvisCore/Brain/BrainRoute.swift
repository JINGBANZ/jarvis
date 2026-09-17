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

    public var requiredCredentials: Set<Credential> {
        Set(targets.compactMap(\.provider.credential))
    }

    /// Index 0 is the primary; `nil` when either position is outside the route. Rebuilding through
    /// `init` keeps the result normalized.
    public func movingTarget(at index: Int, by offset: Int) -> BrainRoute? {
        var reordered = targets
        let (destination, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, reordered.indices.contains(index), reordered.indices.contains(destination) else {
            return nil
        }
        reordered.swapAt(index, destination)
        return BrainRoute(primary: reordered[0], fallbackTargets: Array(reordered.dropFirst()))
    }
}
