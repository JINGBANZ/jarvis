import Foundation

/// Shared by both vendor tables so a status can't be permanent for only one. A refused upgrade
/// has no body, and 408 or 425 describe a moment, so only statuses saying the request can
/// never succeed are permanent. Vendor tables answer auth, access, and quota statuses first.
enum HandshakeRefusal {
    /// 400 malformed, 404 bad URL, 405 bad method, 410 gone, 414/431 too long, 426 wrong protocol.
    private static let permanentStatuses: Set<Int> = [400, 404, 405, 410, 414, 426, 431]

    static func isPermanent(status: Int, stage: ProviderFailure.Stage) -> Bool {
        stage == .handshake && permanentStatuses.contains(status)
    }
}
