import Foundation

public extension ProviderFailure {
    /// The reason a socket transcriber reports when its retry budget runs out: the last observed
    /// cause, relabelled as never-established or lost-after-ready.
    ///
    /// The relabelling is what makes the difference visible to the session lifecycle. A socket that
    /// never reached ready is `.unreachable`, which `endsEverySession` escalates even from the
    /// system-audio side, because the microphone socket shares the same key and the same network
    /// and is about to fail the same way. A socket lost after it was ready is `.disconnected`, a
    /// blip local to that one stream, and the session degrades to microphone-only as before.
    /// The identity and message of the last cause survive, so the row names what actually happened
    /// rather than "the connection was lost".
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
