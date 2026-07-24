import Foundation

/// A provider failure reduced to the two facts the app may act on: whether this one missed turn can
/// recover on a later trigger, and the raw diagnostic detail that stays out of Activity.
public struct BrainFailure: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case temporary
        case terminal
    }

    public let disposition: Disposition
    public let detail: String

    init(_ error: Error) {
        disposition = AgentCLIProcessRunner.isTimeout(error) ? .temporary : .terminal
        detail = error.localizedDescription
    }
}
