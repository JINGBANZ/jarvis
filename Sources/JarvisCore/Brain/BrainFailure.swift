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

    init(_ error: Error) {
        if let failure = error as? BrainFailure {
            self = failure
            return
        }

        // Everything—including new CLI exits, decoding faults, status-like NSError domains, and
        // unknown future errors—is a recoverable missed turn until a provider adapter proves
        // otherwise with the explicit initializer or the typed factory below.
        self.init(disposition: .temporary, detail: error.localizedDescription)
    }

    /// Classify a failed OpenAI Responses request at its adapter boundary. Statuses alone are only
    /// permanent when they directly prove authentication, billing, access, or configuration cannot
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
        let permanent = [401, 402, 403].contains(status)
            || code.map(permanentCodes.contains) == true
            || type.map(permanentTypes.contains) == true
        return BrainFailure(
            disposition: permanent ? .permanent : .temporary,
            detail: detail)
    }
}
