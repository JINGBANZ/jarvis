import Foundation

struct ImmediateClock: _Concurrency.Clock {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {}
}
