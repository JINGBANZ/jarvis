import Foundation

public extension ProviderFailure {
    /// The relabel drives the lifecycle: never-ready becomes `.unreachable`, which ends every
    /// session. The last cause's identity and message are kept so the row names what happened.
    static func exhausted(
        last: ProviderFailure?, source: Source, everReady: Bool
    ) -> ProviderFailure {
        let category: Category = everReady ? .disconnected : .unreachable
        guard let last else {
            return ProviderFailure(
                source: source, stage: everReady ? .transport : .connect, category: category,
                disposition: .temporary, identity: .init(), message: "")
        }
        return ProviderFailure(
            source: source, stage: last.stage, category: category, disposition: .temporary,
            identity: last.identity, message: last.message)
    }
}
