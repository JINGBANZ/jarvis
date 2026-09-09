import Foundation

/// The one reviewed table of what a Gemini failure means, shared by the Live transcriber (handshake
/// status, close code and reason) and the credential check. Google's REST errors carry a gRPC
/// `status` string plus optional `ErrorInfo.reason`; the Live socket carries only a close code and
/// free-text reason. Unknown shapes stay temporary.
public enum GeminiFailureClassifier {
    public static func classify(
        httpStatus: Int, body: Data?, source: ProviderFailure.Source, stage: ProviderFailure.Stage
    ) -> ProviderFailure {
        let error = errorObject(from: body)
        let status = error?["status"] as? String
        let reason = (error?["details"] as? [[String: Any]])?
            .compactMap { $0["reason"] as? String }.first
        let message = error?["message"] as? String ?? ""
        let (category, disposition) = categorize(
            httpStatus: httpStatus, status: status?.uppercased(), reason: reason?.uppercased(),
            message: message.lowercased(), stage: stage)
        return ProviderFailure(
            source: source, stage: stage, category: category, disposition: disposition,
            identity: .init(httpStatus: httpStatus, errorType: status, errorCode: reason),
            message: message)
    }

    /// EMPIRICAL FACT, established against the live endpoint with a deliberately invalid API key:
    /// Gemini does not reject a bad key with an HTTP 401 at the WebSocket handshake, and the Live
    /// API has no error frame at all (see https://ai.google.dev/api/live). The handshake succeeds
    /// and the server closes with 1008, which makes that close the only signal a key was rejected.
    ///
    /// 1008 is Google's generic policy-violation close, though: a retired model id and an
    /// unsupported request shape use it too. All three are permanent, so only the classification
    /// differs, and the free-text reason is the one signal telling them apart. Google does not
    /// document its wording as a stable contract, so this matches a couple of narrow, stable
    /// substrings rather than parsing sentence structure. The default must stay `.configuration`:
    /// an unrecognized reason claiming the key was rejected would send a user to rotate a good key.
    public static func classify(closeCode: Int, reason: String?, source: ProviderFailure.Source) -> ProviderFailure {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch closeCode {
        case 1008:
            let normalized = text.lowercased()
            let isAuthentication = ["authentication", "credential"].contains(where: normalized.contains)
            return ProviderFailure(
                source: source, stage: .close,
                category: isAuthentication ? .authentication : .configuration,
                disposition: .permanent,
                identity: .init(closeCode: closeCode),
                message: text)
        case 1011:
            return ProviderFailure(
                source: source, stage: .close, category: .unavailable, disposition: .temporary,
                identity: .init(closeCode: closeCode), message: text.isEmpty ? "internal server error" : text)
        default:
            return ProviderFailure(
                source: source, stage: .close, category: .disconnected, disposition: .temporary,
                identity: .init(closeCode: closeCode),
                message: text.isEmpty ? "closed with code \(closeCode)" : text)
        }
    }

    private static func categorize(
        httpStatus: Int, status: String?, reason: String?, message: String, stage: ProviderFailure.Stage
    ) -> (ProviderFailure.Category, ProviderFailure.Disposition) {
        if reason == "API_KEY_INVALID" || status == "UNAUTHENTICATED" || httpStatus == 401 {
            return (.authentication, .permanent)
        }
        if status == "PERMISSION_DENIED" || httpStatus == 403 {
            return (.access, .permanent)
        }
        if status == "FAILED_PRECONDITION", message.contains("location") {
            return (.access, .permanent)
        }
        if status == "RESOURCE_EXHAUSTED" || httpStatus == 429 {
            // Google uses one status for rate limits and exhausted free-tier quota; the message
            // says which, and neither may exhaust a target on its own.
            return (.quota, .temporary)
        }
        if status == "NOT_FOUND" || httpStatus == 404 {
            return (.configuration, .permanent)
        }
        switch httpStatus {
        case 400..<500: return (.rejected, stage == .handshake ? .permanent : .temporary)
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
