import Foundation

/// The initializer redacts every provider string, so no adapter can carry raw text past it.
/// Unknown failures stay `.temporary` on purpose; `.permanent` needs reviewed proof.
public struct ProviderFailure: Error, LocalizedError, Sendable, Equatable {
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

        public var surfaceNoun: String {
            switch self {
            case .brain: "coaching"
            case .transcription: "transcription"
            case .capture: "audio capture"
            }
        }
    }

    public enum Stage: String, Sendable {
        /// DNS, TCP, TLS, or proxy failure before any HTTP response.
        case connect
        /// The HTTP response to a WebSocket upgrade was not 101.
        case handshake
        case request
        /// An in-band error event on an open socket.
        case session
        case close
        /// A send or receive on an open socket failed.
        case transport
        /// The socket opened but the provider never acknowledged the session configuration.
        case readiness
        /// A ping/pong probe failed on a ready socket.
        case liveness
        /// The bundled sign-in helper could not serve.
        case process
        /// The answer was unusable (incomplete, no tool call, tool loop).
        case response
        /// Apple Speech or a capture device stopped.
        case local
    }

    /// `unknown` still renders identity and message, never just the word "unknown".
    public enum Category: String, Sendable, CaseIterable {
        case authentication
        case quota
        case access
        case configuration
        /// A connection that never reached ready.
        case unreachable
        /// A connection lost after it was ready, with the retry budget spent.
        case disconnected
        /// Refused for a reason outside the table; the message explains.
        case rejected
        /// 5xx, helper not running, or analyzer gone.
        case unavailable
        case timeout
        case response
        case unknown
    }

    public enum Disposition: Sendable, Equatable {
        case temporary
        case permanent
    }

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

        /// For example "HTTP 403, unsupported_country_region_territory" or "network -1004"; "" when
        /// nothing structured is known.
        public var summary: String {
            var parts: [String] = []
            if let httpStatus { parts.append("HTTP \(httpStatus)") }
            if let closeCode { parts.append("close \(closeCode)") }
            if let transportCode { parts.append("\(Self.scale(of: transportDomain)) \(transportCode)") }
            if let exitStatus { parts.append("exit \(exitStatus)") }
            if let errorCode { parts.append(errorCode) } else if let errorType { parts.append(errorType) }
            return parts.joined(separator: ", ")
        }

        /// Only URL loading codes are "network"; an errno labeled so sends people to check Wi-Fi.
        private static func scale(of domain: String?) -> String {
            switch domain {
            case NSURLErrorDomain: return "network"
            case NSPOSIXErrorDomain: return "errno"
            default: return "code"
            }
        }

        /// Redacts every rendered string, not only vendor-controlled ones: this guards a key.
        func redacted() -> Self {
            var copy = self
            copy.errorType = errorType.map(ProviderMessageRedaction.redact)
            copy.errorCode = errorCode.map(ProviderMessageRedaction.redact)
            copy.transportDomain = transportDomain.map(ProviderMessageRedaction.redact)
            return copy
        }
    }

    public let source: Source
    public let stage: Stage
    public let category: Category
    public let disposition: Disposition
    public let identity: Identity
    /// Redacted provider text; empty when the provider said nothing.
    public let message: String

    public init(
        source: Source, stage: Stage, category: Category, disposition: Disposition,
        identity: Identity, message: String
    ) {
        self.source = source
        self.stage = stage
        self.category = category
        self.disposition = disposition
        // A WebSocket close reason is free text the server chose, so identity is redacted too.
        self.identity = identity.redacted()
        self.message = ProviderMessageRedaction.redact(message)
    }

    /// For errors nothing is proven about. Stays temporary, and transport errors use the fixed
    /// descriptions so a failing URL (Gemini's carries the API key) never becomes the message.
    public init(unclassified error: any Error, source: Source, stage: Stage) {
        if let failure = error as? ProviderFailure {
            self = failure
            return
        }
        let nsError = error as NSError
        if TransportFailureClassifier.isTransportDomain(nsError.domain) {
            // Callers that know a socket was ready use the classifier directly.
            self = TransportFailureClassifier.classify(error: error, source: source, everReady: false)
            return
        }
        self.init(
            source: source, stage: stage, category: .unknown, disposition: .temporary,
            identity: .init(transportDomain: nsError.domain, transportCode: nsError.code),
            message: nsError.localizedDescription)
    }

    /// Both transcription sockets share one key and network, so a permanent or unreachable failure
    /// would repeat on the mic side. Post-ready drops and `.local` failures stay stream-local.
    public var endsEverySession: Bool {
        guard stage != .local else { return false }
        return disposition == .permanent || category == .unreachable
    }

    public var errorDescription: String? {
        [identity.summary, message].filter { !$0.isEmpty }.joined(separator: ": ")
    }
}
