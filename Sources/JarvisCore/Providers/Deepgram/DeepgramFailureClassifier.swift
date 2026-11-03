import Foundation

/// Deepgram's REST and upgrade errors carry `err_code` and `err_msg`; its socket carries only a
/// close code and a free-text reason. Unknown shapes stay temporary.
public enum DeepgramFailureClassifier {
    public static func classify(
        httpStatus: Int, body: Data?, source: ProviderFailure.Source, stage: ProviderFailure.Stage
    ) -> ProviderFailure {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = object?["err_code"] as? String
        let message = object?["err_msg"] as? String
            ?? body.flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        let (category, disposition) = categorize(httpStatus: httpStatus, stage: stage)
        return ProviderFailure(
            source: source, stage: stage, category: category, disposition: disposition,
            identity: .init(httpStatus: httpStatus, errorCode: code),
            message: message)
    }

    /// Deepgram documents 1008 for audio it cannot decode and 1011 for a server fault or an idle
    /// timeout, so neither proves the key or the request shape is wrong.
    public static func classify(closeCode: Int, reason: String?, source: ProviderFailure.Source) -> ProviderFailure {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (category, fallback): (ProviderFailure.Category, String) = switch closeCode {
        case 1008: (.rejected, "audio rejected")
        case 1011: (.unavailable, "internal server error")
        default: (.disconnected, "closed with code \(closeCode)")
        }
        return ProviderFailure(
            source: source, stage: .close, category: category, disposition: .temporary,
            identity: .init(closeCode: closeCode), message: text.isEmpty ? fallback : text)
    }

    private static func categorize(
        httpStatus: Int, stage: ProviderFailure.Stage
    ) -> (ProviderFailure.Category, ProviderFailure.Disposition) {
        switch httpStatus {
        case 401: (.authentication, .permanent)
        case 402: (.quota, .permanent)
        case 403: (.access, .permanent)
        case 429: (.quota, .temporary)
        case 400..<500:
            (.rejected, HandshakeRefusal.isPermanent(status: httpStatus, stage: stage) ? .permanent : .temporary)
        case 500..<600: (.unavailable, .temporary)
        default: (.unknown, .temporary)
        }
    }
}
