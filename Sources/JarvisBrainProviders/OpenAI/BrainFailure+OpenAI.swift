import Foundation
import JarvisCore

// OpenAI-specific failure classification lives beside the OpenAI adapter, not in Core:
// `BrainFailure` stays provider-neutral, and the reviewed proof of what is permanent for this
// provider is owned by the boundary that produces it.
extension BrainFailure {
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
