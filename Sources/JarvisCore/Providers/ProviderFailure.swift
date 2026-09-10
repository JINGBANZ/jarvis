import Foundation

/// One failure observed at a provider boundary, classified where it was observed and carried
/// unchanged to the route policy, the session lifecycle, Activity, and the debug log.
///
/// Two kinds of consumer read two different parts and nothing else. Policy (route advance, socket
/// retry, session end) reads `disposition` and `endsEverySession`. People read `category` for the
/// fixed sentence and advice, and `identity` plus `message` for what the provider actually said.
/// `message` is always redacted provider text: both initializers redact unconditionally, so no
/// adapter can carry raw text past this type.
///
/// Unknown failures deliberately classify as `.temporary`: losing one coaching turn, or spending a
/// bounded retry budget on a socket, is safer than exhausting a target because a new provider
/// error was not yet in the table. A vendor classifier creates `.permanent` only from reviewed
/// proof that this target cannot recover.
public struct ProviderFailure: Error, LocalizedError, Sendable, Equatable {
    /// Which boundary produced the failure. The provider enums carry the display names.
    public enum Source: Sendable, Equatable {
        case brain(BrainProvider)
        case transcription(TranscriptionProvider)
        /// The aggregate audio device feeding both transcription sockets.
        case capture

        public var displayName: String {
            switch self {
            case .brain(let provider): provider.displayName
            case .transcription(let provider): provider.displayName
            case .capture: "Audio capture"
            }
        }

        /// The noun the sentence uses for what the provider was doing for Jarvis.
        public var surfaceNoun: String {
            switch self {
            case .brain: "coaching"
            case .transcription: "transcription"
            case .capture: "audio capture"
            }
        }
    }

    /// Where in the exchange the failure surfaced.
    public enum Stage: String, Sendable {
        /// DNS, TCP, TLS, or proxy failure before any HTTP response.
        case connect
        /// The HTTP response to a WebSocket upgrade was not 101.
        case handshake
        /// A plain HTTP request and response (a brain call, a credential check).
        case request
        /// An in-band error event on an open socket.
        case session
        /// The server closed the socket.
        case close
        /// A send or receive on an open socket failed.
        case transport
        /// The socket opened but the provider never acknowledged the session configuration.
        case readiness
        /// A ping/pong liveness probe failed on a ready socket.
        case liveness
        /// A local CLI process exited, timed out, or produced unusable output.
        case process
        /// The provider answered but the answer was unusable (incomplete, no tool call, tool loop).
        case response
        /// A local analyzer (Apple Speech) or capture device stopped.
        case local
    }

    /// Selects the fixed sentence and advice Activity shows. `unknown` still renders identity and
    /// message, so an unclassified failure is never reduced to the word "unknown".
    public enum Category: String, Sendable, CaseIterable {
        case authentication
        case quota
        case access
        case configuration
        /// A connection that never reached ready.
        case unreachable
        /// A connection lost after it was ready, with the retry budget spent.
        case disconnected
        /// The provider refused for a reason outside the table; the message explains.
        case rejected
        /// The provider or a local resource is unavailable (5xx, CLI missing, analyzer gone).
        case unavailable
        case timeout
        /// The provider's response could not be used.
        case response
        case unknown
    }

    public enum Disposition: Sendable, Equatable {
        case temporary
        case permanent
    }

    /// Structured, grep-able identity. Each stage exposes a different subset, so every field is
    /// optional; `summary` renders whichever are present.
    public struct Identity: Sendable, Equatable {
        public var httpStatus: Int?
        public var closeCode: Int?
        public var errorType: String?
        public var errorCode: String?
        public var transportDomain: String?
        public var transportCode: Int?
        public var exitStatus: Int32?

        public init(
            httpStatus: Int? = nil, closeCode: Int? = nil, errorType: String? = nil,
            errorCode: String? = nil, transportDomain: String? = nil, transportCode: Int? = nil,
            exitStatus: Int32? = nil
        ) {
            self.httpStatus = httpStatus
            self.closeCode = closeCode
            self.errorType = errorType
            self.errorCode = errorCode
            self.transportDomain = transportDomain
            self.transportCode = transportCode
            self.exitStatus = exitStatus
        }

        /// "HTTP 403, unsupported_country_region_territory", "close 3000, insufficient_permissions",
        /// "network -1004", "errno 32", "code 500", "exit 1", or "" when nothing structured is known.
        public var summary: String {
            var parts: [String] = []
            if let httpStatus { parts.append("HTTP \(httpStatus)") }
            if let closeCode { parts.append("close \(closeCode)") }
            if let transportCode { parts.append("\(Self.scale(of: transportDomain)) \(transportCode)") }
            if let exitStatus { parts.append("exit \(exitStatus)") }
            if let errorCode { parts.append(errorCode) } else if let errorType { parts.append(errorType) }
            return parts.joined(separator: ", ")
        }

        /// A number means nothing without saying which numbering it belongs to. Only URL loading
        /// codes are "network"; an errno and an adapter's own code are different scales entirely,
        /// and calling all three "network" sent a person to check their Wi-Fi over a CLI that
        /// exited badly.
        private static func scale(of domain: String?) -> String {
            switch domain {
            case NSURLErrorDomain: return "network"
            case NSPOSIXErrorDomain: return "errno"
            default: return "code"
            }
        }
    }

    public let source: Source
    public let stage: Stage
    public let category: Category
    public let disposition: Disposition
    public let identity: Identity
    /// Provider text after `ProviderMessageRedaction.redact`; empty when the provider said nothing.
    public let message: String

    public init(
        source: Source, stage: Stage, category: Category, disposition: Disposition,
        identity: Identity, message: String
    ) {
        self.source = source
        self.stage = stage
        self.category = category
        self.disposition = disposition
        self.identity = identity
        self.message = ProviderMessageRedaction.redact(message)
    }

    /// Every adapter's entry point for an error it has not proven anything about: a decoding fault,
    /// a CLI exit, an unknown future error. Keeps the NSError identity, stays temporary, and routes
    /// transport errors through the fixed-description table so a failing URL (which for Gemini
    /// carries the API key) never becomes the message.
    public init(unclassified error: any Error, source: Source, stage: Stage) {
        if let failure = error as? ProviderFailure {
            self = failure
            return
        }
        let nsError = error as NSError
        if TransportFailureClassifier.isTransportDomain(nsError.domain) {
            // Callers that know a socket was ready use the classifier directly; anything reaching
            // this default path is a request or first connection that could not be reached.
            self = TransportFailureClassifier.classify(error: error, source: source, everReady: false)
            return
        }
        self.init(
            source: source, stage: stage, category: .unknown, disposition: .temporary,
            identity: .init(transportDomain: nsError.domain, transportCode: nsError.code),
            message: nsError.localizedDescription)
    }

    /// Whether a system-audio-side failure must end the whole session rather than degrade to
    /// microphone-only. Both transcription sockets share one key and one network, so a permanent
    /// account/access/configuration rejection or a connection that never came up will repeat on
    /// the mic side seconds later; degrading first would hide the cause behind a system-audio
    /// notice. A socket lost after it was ready is a transport blip local to that stream, and a
    /// `.local` failure (Apple Speech, capture) has no shared account or network surface.
    public var endsEverySession: Bool {
        guard stage != .local else { return false }
        return disposition == .permanent || category == .unreachable
    }

    public var errorDescription: String? {
        [identity.summary, message].filter { !$0.isEmpty }.joined(separator: ": ")
    }
}
