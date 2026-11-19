import Foundation

public struct SpeechInterval: Equatable, Sendable {
    public let startedAt: TimeInterval
    public let endedAt: TimeInterval

    public init?(startedAt: TimeInterval, endedAt: TimeInterval) {
        guard startedAt.isFinite, endedAt.isFinite, startedAt >= 0, endedAt >= startedAt else { return nil }
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
