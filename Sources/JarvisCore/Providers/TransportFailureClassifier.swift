import Foundation

/// Turns a transport-level failure (no HTTP response, or the socket died) into a `ProviderFailure`
/// without ever stringifying the error. `URLError.localizedDescription` and its user info embed the
/// failing URL; for Gemini that URL carries the API key. Every message here comes from a fixed
/// table keyed on the error code, so this classifier is safe for every caller.
public enum TransportFailureClassifier {
    public static func isTransportDomain(_ domain: String) -> Bool {
        domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain
    }

    /// `everReady` distinguishes a connection that never came up (`.unreachable`, escalates) from
    /// one lost after it was ready (`.disconnected`, stream-local). A timeout is its own category
    /// because the advice differs: nothing is refusing, something is slow.
    public static func classify(
        error: any Error, source: ProviderFailure.Source, everReady: Bool
    ) -> ProviderFailure {
        let nsError = error as NSError
        let isTimeout = nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue
        let category: ProviderFailure.Category = isTimeout ? .timeout : (everReady ? .disconnected : .unreachable)
        return ProviderFailure(
            source: source,
            stage: everReady ? .transport : .connect,
            category: category,
            disposition: .temporary,
            identity: .init(transportDomain: nsError.domain, transportCode: nsError.code),
            message: description(domain: nsError.domain, code: nsError.code))
    }

    public static func readinessTimeout(
        seconds: TimeInterval, source: ProviderFailure.Source, everReady: Bool
    ) -> ProviderFailure {
        ProviderFailure(
            source: source, stage: .readiness,
            category: everReady ? .disconnected : .unreachable,
            disposition: .temporary, identity: .init(),
            message: "no session acknowledgement within \(Int(seconds))s")
    }

    public static func livenessTimeout(seconds: TimeInterval, source: ProviderFailure.Source) -> ProviderFailure {
        ProviderFailure(
            source: source, stage: .liveness, category: .disconnected, disposition: .temporary,
            identity: .init(), message: "no pong within \(Int(seconds))s")
    }

    static func description(domain: String, code: Int) -> String {
        switch domain {
        case NSURLErrorDomain:
            switch URLError.Code(rawValue: code) {
            case .timedOut: return "the request timed out"
            case .cannotFindHost: return "the server could not be found"
            case .cannotConnectToHost: return "could not connect to the server"
            case .networkConnectionLost: return "the network connection was lost"
            case .dnsLookupFailed: return "the DNS lookup failed"
            case .notConnectedToInternet: return "the internet connection appears to be offline"
            // Deliberately not "refused the WebSocket upgrade": this table is shared by the brain
            // HTTP adapter and the credential check, which have no socket. A refused upgrade that
            // carries a status is classified from that status by the vendor table before reaching
            // here anyway, so the specific wording bought nothing and misnamed two other callers.
            case .badServerResponse: return "the server sent an unusable response"
            case .cannotParseResponse: return "the server response could not be parsed"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "a secure connection could not be made"
            case .appTransportSecurityRequiresSecureConnection: return "the connection was blocked by App Transport Security"
            case .cancelled: return "the connection was cancelled"
            default: return "network error \(code)"
            }
        case NSPOSIXErrorDomain:
            switch Int32(code) {
            case ECONNRESET: return "connection reset by peer"
            case ENOTCONN: return "socket is not connected"
            case ECONNREFUSED: return "connection refused"
            case ETIMEDOUT: return "operation timed out"
            case ENETDOWN: return "network is down"
            case ENETUNREACH: return "network is unreachable"
            case EHOSTUNREACH: return "no route to host"
            case EPIPE: return "broken pipe"
            default: return "POSIX error \(code)"
            }
        default:
            return "\(domain) error \(code)"
        }
    }
}
