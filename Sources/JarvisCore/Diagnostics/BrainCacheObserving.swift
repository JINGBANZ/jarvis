import Foundation

public protocol BrainCacheObserving: Sendable {
    func observe(
        request: Data,
        response: Data?,
        context: CoachingRequestContext?
    ) -> BrainCacheObservation?
}
