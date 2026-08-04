import Foundation

/// Content-free local speech edges delivered by the capture adapter. `commitAt` is the capture
/// boundary through which audio must reach the provider before an explicit turn commit is sent.
public enum LocalSpeechEvent: Equatable, Sendable {
    case started(at: TimeInterval)
    case ended(startedAt: TimeInterval, commitAt: TimeInterval)
}
