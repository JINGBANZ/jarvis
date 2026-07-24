import Foundation

/// The single provider-boundary failure policy shared by immediate retry and session lifecycle.
///
/// Unknown live-turn failures deliberately default to `.temporary`: losing one coaching turn is
/// safer than destroying the transcript, capture pipeline, and conversation because a new provider
/// error was not yet classified. A failure may stop the session only when a provider adapter creates
/// an explicit `.terminal` value from a small, reviewed proof that the provider is unusable.
/// Raw detail stays in diagnostics and never enters Activity.
public struct BrainFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case temporary
        case terminal
    }

    public let disposition: Disposition
    /// Whether the exact self-contained request may be repeated immediately. This is independent
    /// from `disposition`: rate limiting and a CLI watchdog miss preserve the session but should wait
    /// for a later trigger instead of immediately repeating an expensive or throttled request.
    public let retriesImmediately: Bool
    public let detail: String

    public var errorDescription: String? { detail }

    public init(disposition: Disposition, retriesImmediately: Bool = false, detail: String) {
        precondition(disposition == .temporary || !retriesImmediately,
                     "a terminal brain failure cannot be retried")
        self.disposition = disposition
        self.retriesImmediately = retriesImmediately
        self.detail = detail
    }

    init(_ error: Error) {
        if let failure = error as? BrainFailure {
            self = failure
            return
        }

        let ns = error as NSError
        let retriesImmediately: Bool
        if ns.domain == NSURLErrorDomain {
            retriesImmediately = [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorSecureConnectionFailed,
            ].contains(ns.code)
        } else {
            retriesImmediately = false
        }

        // Everything—including new CLI exits, decoding faults, status-like NSError domains, and
        // unknown future errors—is a recoverable missed turn until a provider adapter proves
        // otherwise with the explicit initializer or the typed factory below.
        self.init(disposition: .temporary, retriesImmediately: retriesImmediately,
                  detail: error.localizedDescription)
    }

    /// Classify a failed OpenAI Responses request at its adapter boundary. Statuses alone are only
    /// terminal when they directly prove authentication, billing, access, or configuration cannot
    /// recover. Request-local and unknown future 4xx responses deliberately stay temporary.
    static func openAIHTTP(status: Int, errorCode: String?, errorType: String?,
                           detail: String) -> BrainFailure {
        let code = errorCode?.lowercased()
        let type = errorType?.lowercased()
        let permanentCodes: Set<String> = [
            "account_deactivated",
            "billing_hard_limit_reached",
            "billing_not_active",
            "insufficient_quota",
            "invalid_api_key",
            "model_not_found",
            "organization_deactivated",
            "permission_denied",
            "unsupported_country_region_territory",
        ]
        let permanentTypes: Set<String> = [
            "authentication_error",
            "permission_error",
        ]
        let terminal = [401, 402, 403, 404].contains(status)
            || code.map(permanentCodes.contains) == true
            || type.map(permanentTypes.contains) == true
        let retriesImmediately = status == 408 || status == 409 || (500..<600).contains(status)
        return BrainFailure(
            disposition: terminal ? .terminal : .temporary,
            retriesImmediately: !terminal && retriesImmediately,
            detail: detail)
    }
}
