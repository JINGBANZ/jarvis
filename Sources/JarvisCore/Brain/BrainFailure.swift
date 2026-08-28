import Foundation

/// Provider-boundary classification consumed by the ordered route policy.
///
/// Unknown live-turn failures deliberately default to `.temporary`: losing one coaching turn is
/// safer than exhausting a target because a new provider error was not yet classified. A provider
/// adapter creates `.permanent` only from small, reviewed proof that this target cannot recover.
/// Raw detail stays in diagnostics and never enters Activity.
public struct BrainFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case temporary
        case permanent
    }

    public let disposition: Disposition
    public let detail: String

    public var errorDescription: String? { detail }

    public init(disposition: Disposition, detail: String) {
        self.disposition = disposition
        self.detail = detail
    }

    /// Public because it is every provider adapter's classification entry point for errors it has
    /// not proven anything about — including adapters composed outside this module
    /// (`JarvisBrainProviders`).
    public init(_ error: Error) {
        if let failure = error as? BrainFailure {
            self = failure
            return
        }

        // Everything—including new CLI exits, decoding faults, status-like NSError domains, and
        // unknown future errors—is a recoverable missed turn until a provider adapter proves
        // otherwise with the explicit initializer or a typed adapter-side factory (such as the
        // OpenAI HTTP classifier in `JarvisBrainProviders`).
        self.init(disposition: .temporary, detail: error.localizedDescription)
    }
}
