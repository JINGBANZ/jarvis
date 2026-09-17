import Foundation

/// Content-free. Audio through `commitAt` must reach the provider before the turn commit is sent.
public enum LocalSpeechEvent: Equatable, Sendable {
    case started(at: TimeInterval)
    case ended(startedAt: TimeInterval, commitAt: TimeInterval)
}
