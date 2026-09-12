import Foundation

/// The one reviewed table of what an OpenAI failure means, shared by the brain HTTP adapter, the
/// Realtime transcriber (handshake status, in-band events, close reasons), and the credential
/// check. Statuses alone are permanent only when they prove authentication, billing, or access
/// cannot recover. A WebSocket upgrade refused with one of the statuses in `HandshakeRefusal` is
/// equally permanent because the request cannot succeed as sent, while the rest of the 4xx range,
/// at a handshake or on a plain request, deliberately stays temporary.
public enum OpenAIFailureClassifier {
    public static func classify(
        httpStatus: Int, body: Data?, source: ProviderFailure.Source, stage: ProviderFailure.Stage
    ) -> ProviderFailure {
        let error = errorObject(from: body)
        let code = error?["code"] as? String
        let type = error?["type"] as? String
        let param = error?["param"] as? String
        let (category, disposition) = categorize(status: httpStatus, code: code, type: type, param: param, stage: stage)
        let message = error?["message"] as? String
            ?? body.flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        return ProviderFailure(
            source: source, stage: stage, category: category, disposition: disposition,
            identity: .init(httpStatus: httpStatus, errorType: type, errorCode: code),
            message: message)
    }

    /// In-band Realtime errors. Realtime also uses the failed-transcription event for item-local
    /// failures such as `audio_unintelligible`, so an unrecognized code stays temporary rather than
    /// tearing down an otherwise usable session. Returns nil for any other event type.
    public static func classify(event: [String: Any], source: ProviderFailure.Source) -> ProviderFailure? {
        guard let eventType = event["type"] as? String,
              eventType == RealtimeSession.failedTranscriptionType || eventType == "error",
              let error = event["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String
        let type = error["type"] as? String
        // Only a session-level rejection of a `session.*` parameter is a configuration failure; the
        // same code on an item is utterance-local.
        let param = eventType == "error" ? error["param"] as? String : nil
        let (category, disposition) = categorize(status: nil, code: code, type: type, param: param, stage: .session)
        return ProviderFailure(
            source: source, stage: .session, category: category, disposition: disposition,
            identity: .init(errorType: type, errorCode: code),
            message: error["message"] as? String ?? "")
    }

    /// OpenAI closes a rejected Realtime session with code 3000 and a reason of the form
    /// `<type>.<code>`; every other close is transport-level and stays temporary.
    public static func classify(closeCode: Int, reason: String?, source: ProviderFailure.Source) -> ProviderFailure {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if closeCode == 3000, !trimmed.isEmpty {
            // `<type>.<code>` is the documented shape, but a reason arriving as a bare code still
            // names a rejection. Reading it as a transport close instead would spend the whole
            // retry budget on a key the server has already refused.
            //
            // A close reason is free text the server chose, so only the halves that actually look
            // like codes become identity. A sentence is not an identifier, and rendering one in the
            // identity would repeat the message back beside itself in the row; the message already
            // carries whatever the server said.
            let separator = trimmed.firstIndex(of: ".")
            let type = separator.flatMap { Self.errorCodeIfIdentifier(String(trimmed[..<$0])) }
            let code = Self.errorCodeIfIdentifier(
                separator.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed)
            let (category, disposition) = categorize(status: nil, code: code, type: type, param: nil, stage: .close)
            return ProviderFailure(
                source: source, stage: .close,
                category: category == .unknown ? .rejected : category,
                disposition: disposition,
                identity: .init(closeCode: closeCode, errorType: type, errorCode: code),
                message: trimmed)
        }
        let message: String
        switch closeCode {
        case 1001: message = "server going away"
        case 1000: message = "closed normally by the server"
        default: message = trimmed.isEmpty ? "closed with code \(closeCode)" : trimmed
        }
        return ProviderFailure(
            source: source, stage: .close, category: .disconnected, disposition: .temporary,
            identity: .init(closeCode: closeCode), message: message)
    }

    static func categorize(
        status: Int?, code: String?, type: String?, param: String?, stage: ProviderFailure.Stage
    ) -> (ProviderFailure.Category, ProviderFailure.Disposition) {
        switch code?.lowercased() {
        case "invalid_api_key":
            return (.authentication, .permanent)
        case "insufficient_quota", "billing_hard_limit_reached", "billing_not_active":
            return (.quota, .permanent)
        case "permission_denied", "organization_deactivated", "account_deactivated",
             "unsupported_country_region_territory":
            return (.access, .permanent)
        case "model_not_found":
            return (.configuration, .permanent)
        case "invalid_value" where param?.lowercased().hasPrefix("session.") == true:
            return (.configuration, .permanent)
        case "rate_limit_exceeded":
            return (.rejected, .temporary)
        case "server_error":
            return (.unavailable, .temporary)
        case "session_expired":
            return (.disconnected, .temporary)
        default:
            break
        }
        switch type?.lowercased() {
        case "authentication_error": return (.authentication, .permanent)
        case "permission_error": return (.access, .permanent)
        case "insufficient_quota": return (.quota, .permanent)
        default: break
        }
        // In-band events and close reasons carry no HTTP status, and the status ranges below cannot
        // be matched against an optional. A missing status leaves the failure unknown, same as an
        // unrecognized one.
        guard let status else { return (.unknown, .temporary) }
        switch status {
        case 401: return (.authentication, .permanent)
        case 402: return (.quota, .permanent)
        case 403: return (.access, .permanent)
        case 429: return (.rejected, .temporary)
        case 400..<500:
            return (.rejected, HandshakeRefusal.isPermanent(status: status, stage: stage) ? .permanent : .temporary)
        case 500..<600: return (.unavailable, .temporary)
        default: return (.unknown, .temporary)
        }
    }

    /// The text back if it is shaped like a vendor error code, otherwise nil. OpenAI's codes are
    /// short ASCII identifiers (`invalid_api_key`, `insufficient_quota`); anything with a space or a
    /// colon in it is the server explaining itself, which belongs in the message alone.
    private static func errorCodeIfIdentifier(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= 64,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return text
    }

    private static func errorObject(from body: Data?) -> [String: Any]? {
        guard let body, !body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return root["error"] as? [String: Any]
    }
}
