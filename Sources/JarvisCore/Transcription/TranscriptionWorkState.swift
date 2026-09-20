import Foundation

public enum TranscriptionWorkState: Equatable, Sendable {
    case settled
    /// Earliest unresolved start on the session clock; nil means timing is unknown.
    case pending(since: TimeInterval?)

    public func permitsCoaching(through spokenAt: TimeInterval?) -> Bool {
        switch self {
        case .settled:
            return true
        case .pending(let earliest):
            guard let earliest, earliest.isFinite, earliest >= 0,
                  let spokenAt, spokenAt.isFinite else { return false }
            return earliest > spokenAt
        }
    }
}
