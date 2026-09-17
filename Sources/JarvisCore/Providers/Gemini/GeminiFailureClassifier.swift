import Foundation

/// Google's REST errors carry a gRPC `status` plus an optional `ErrorInfo.reason`; the Live socket
/// carries only a close code and free-text reason. Unknown shapes stay temporary.
public enum GeminiFailureClassifier {
    public static func classify(
        httpStatus: Int, body: Data?, source: ProviderFailure.Source, stage: ProviderFailure.Stage
    ) -> ProviderFailure {
        let error = errorObject(from: body)
        let status = error?["status"] as? String
        let reason = (error?["details"] as? [[String: Any]])?
            .compactMap { $0["reason"] as? String }.first
        // A non-JSON body (edge HTML, proxy text) is still what the server said, so quote it.
        let message = error?["message"] as? String
            ?? body.flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        let (category, disposition) = categorize(
            httpStatus: httpStatus, status: status?.uppercased(), reason: reason?.uppercased(),
            message: message.lowercased(), stage: stage)
        return ProviderFailure(
            source: source, stage: stage, category: category, disposition: disposition,
            identity: .init(httpStatus: httpStatus, errorType: status, errorCode: reason),
            message: message)
    }

    /// Verified live: Gemini accepts the handshake for a bad key and closes with 1008, since the
    /// Live API has no error frame. 1008 also covers a retired model or bad request shape, and the
    /// reason wording is undocumented, so match narrow substrings. Default to `.configuration` so
    /// an unrecognized reason never sends a user to rotate a good key.
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
            // One status covers rate limits and spent free-tier quota, so it stays temporary.
            return (.quota, .temporary)
        }
        if status == "NOT_FOUND" || httpStatus == 404 {
            return (.configuration, .permanent)
        }
        switch httpStatus {
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
