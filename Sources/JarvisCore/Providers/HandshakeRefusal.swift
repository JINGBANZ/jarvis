import Foundation

/// Whether a 4xx on a WebSocket upgrade proves the socket can never come up, shared by both vendor
/// tables so one status cannot be permanent for OpenAI and temporary for Gemini.
///
/// A refused upgrade carries no body to read, so the status is the whole evidence, and the stage
/// alone is not proof: 408 and 425 describe a moment, not a contract, and an edge or proxy that
/// answers one of them would otherwise end the session immediately with no retry at all. Only the
/// statuses below say the request itself cannot succeed as sent, however many times it is repeated.
/// Everything else in the range stays temporary and spends the bounded first-connect budget, which
/// keeps the record's rule intact: permanent comes from reviewed proof, never from a default.
///
/// Authentication, access, and quota statuses never reach here; the vendor tables answer those
/// above this range, so this list is only the codes that describe the request or the route.
enum HandshakeRefusal {
    /// 400 malformed, 404 wrong URL, 405 wrong method, 410 withdrawn, 414 and 431 too long, 426
    /// wrong protocol. None of these answer differently on a second attempt.
    private static let permanentStatuses: Set<Int> = [400, 404, 405, 410, 414, 426, 431]

    static func isPermanent(status: Int, stage: ProviderFailure.Stage) -> Bool {
        stage == .handshake && permanentStatuses.contains(status)
    }
}
