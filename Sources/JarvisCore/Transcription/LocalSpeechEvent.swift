import Foundation

/// Content-free. Audio through `commitAt` must reach the provider before the turn commit is sent.
public enum LocalSpeechEvent: Equatable, Sendable {
    case started(at: TimeInterval)
    case ended(startedAt: TimeInterval, endedAt: TimeInterval? = nil, commitAt: TimeInterval)
}

public extension LocalSpeechEvent {
    var activity: (active: Bool, at: TimeInterval) {
        switch self {
        case .started(let at): (true, at)
        case .ended(_, let endedAt, let commitAt): (false, endedAt ?? commitAt)
        }
    }

    func relative(to origin: TimeInterval) -> LocalSpeechEvent {
        switch self {
        case .started(let at):
            return .started(at: max(0, at - origin))
        case .ended(let start, let end, let commit):
            return .ended(startedAt: max(0, start - origin),
                          endedAt: end.map { max(0, $0 - origin) },
                          commitAt: max(0, commit - origin))
        }
    }
}
