import Foundation

/// Anthropic's errors carry one `type` and a message. The bundled helper answers its Messages
/// route in the same shape, so one table serves the vendor and the helper. Unknown shapes stay
/// temporary.
public enum AnthropicFailureClassifier {
    public static func classify(
        httpStatus: Int, body: Data?, source: ProviderFailure.Source, stage: ProviderFailure.Stage
    ) -> ProviderFailure {
        let error = errorObject(from: body)
        let type = error?["type"] as? String
        // A non-JSON body (edge HTML, proxy text) is still what the server said, so quote it.
        let message = error?["message"] as? String
            ?? body.flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        let (category, disposition) = categorize(httpStatus: httpStatus, type: type?.lowercased(), stage: stage)
        return ProviderFailure(
            source: source, stage: stage, category: category, disposition: disposition,
            identity: .init(httpStatus: httpStatus, errorType: type),
            message: message)
    }

    private static func categorize(
        httpStatus: Int, type: String?, stage: ProviderFailure.Stage
    ) -> (ProviderFailure.Category, ProviderFailure.Disposition) {
        switch type {
        case "authentication_error": return (.authentication, .permanent)
        case "permission_error": return (.access, .permanent)
        case "billing_error": return (.quota, .permanent)
        // The helper's own answer for a model it cannot route reads `unknown provider for model`.
        case "invalid_request_error", "not_found_error": return (.configuration, .permanent)
        // Subscription Activity reads a 429 rejection as the plan's usage limit.
        case "rate_limit_error": return (.rejected, .temporary)
        case "overloaded_error", "api_error": return (.unavailable, .temporary)
        default: break
        }
        switch httpStatus {
        case 401: return (.authentication, .permanent)
        case 402: return (.quota, .permanent)
        case 403: return (.access, .permanent)
        case 404: return (.configuration, .permanent)
        case 429: return (.rejected, .temporary)
        case 400..<500:
            return (.rejected, HandshakeRefusal.isPermanent(status: httpStatus, stage: stage) ? .permanent : .temporary)
        case 500..<600: return (.unavailable, .temporary)
        default: return (.unknown, .temporary)
        }
    }

    private static func errorObject(from body: Data?) -> [String: Any]? {
        guard let body, !body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return root["error"] as? [String: Any]
    }
}
