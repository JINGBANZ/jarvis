import Foundation
import Testing
@testable import JarvisCore

@Suite struct GeminiFailureClassifierTests {
    /// A body that is not Google's error JSON, an edge's HTML page or a proxy's plain text, is
    /// still the only thing the server said. Dropping it left the row with a status and nothing else.
    @Test func quotesABodyThatIsNotGoogleErrorJSON() {
        let failure = GeminiFailureClassifier.classify(
            httpStatus: 502,
            body: Data("upstream connect error or disconnect".utf8),
            source: .transcription(.gemini),
            stage: .handshake)
        #expect(failure.message == "upstream connect error or disconnect")
        #expect(failure.identity.httpStatus == 502)
    }

    private let source = ProviderFailure.Source.transcription(.gemini)

    private func body(status: String, message: String, reason: String? = nil) -> Data {
        var error: [String: Any] = ["status": status, "message": message]
        if let reason {
            error["details"] = [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason]]
        }
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    /// Google reports a bad key as HTTP 400 INVALID_ARGUMENT with ErrorInfo reason API_KEY_INVALID,
    /// and an unsupported region as HTTP 400 FAILED_PRECONDITION naming the user's location.
    @Test func restErrorsFollowGoogleStatusesAndReasons() {
        let badKey = GeminiFailureClassifier.classify(
            httpStatus: 400, body: body(status: "INVALID_ARGUMENT", message: "API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"),
            source: source, stage: .request)
        #expect(badKey.category == .authentication && badKey.disposition == .permanent)
        #expect(badKey.identity == .init(httpStatus: 400, errorType: "INVALID_ARGUMENT", errorCode: "API_KEY_INVALID"))
        #expect(badKey.message == "API key not valid. Please pass a valid API key.")

        let region = GeminiFailureClassifier.classify(
            httpStatus: 400, body: body(status: "FAILED_PRECONDITION", message: "User location is not supported for the API use."),
            source: source, stage: .request)
        #expect(region.category == .access && region.disposition == .permanent)

        let denied = GeminiFailureClassifier.classify(httpStatus: 403, body: body(status: "PERMISSION_DENIED", message: "m"), source: source, stage: .request)
        #expect(denied.category == .access && denied.disposition == .permanent)
        let quota = GeminiFailureClassifier.classify(httpStatus: 429, body: body(status: "RESOURCE_EXHAUSTED", message: "quota"), source: source, stage: .request)
        #expect(quota.category == .quota && quota.disposition == .temporary)
        let model = GeminiFailureClassifier.classify(httpStatus: 404, body: body(status: "NOT_FOUND", message: "model"), source: source, stage: .request)
        #expect(model.category == .configuration && model.disposition == .permanent)
        let down = GeminiFailureClassifier.classify(httpStatus: 503, body: nil, source: source, stage: .request)
        #expect(down.category == .unavailable && down.disposition == .temporary)
        let unknown400 = GeminiFailureClassifier.classify(httpStatus: 400, body: nil, source: source, stage: .request)
        #expect(unknown400.category == .rejected && unknown400.disposition == .temporary)
        let handshake400 = GeminiFailureClassifier.classify(httpStatus: 400, body: nil, source: source, stage: .handshake)
        #expect(handshake400.disposition == .permanent)
        // Both vendors read one shared list, so a status cannot be permanent here and retryable
        // there. A handshake timeout keeps the three-attempt budget rather than ending the session.
        let handshake408 = GeminiFailureClassifier.classify(httpStatus: 408, body: nil, source: source, stage: .handshake)
        #expect(handshake408.disposition == .temporary)
        #expect(!handshake408.endsEverySession)
    }

    /// 1008 is Google's generic policy-violation close: a rejected key, a retired model id, and an
    /// unsupported request shape all use it, and only the reason text tells them apart. The default
    /// must stay `.configuration`, never `.authentication`, so an unrecognized reason cannot send a
    /// user to rotate a good key. Captured wording for a rejected key: "Request had invalid
    /// authentication credentials. Expected OAuth 2 access token, login cookie or other valid
    /// authentication credential...".
    @Test func policyViolationClosesSplitOnReasonText() {
        let auth = GeminiFailureClassifier.classify(
            closeCode: 1008, reason: "Request had invalid authentication credentials. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.",
            source: source)
        #expect(auth.category == .authentication && auth.disposition == .permanent && auth.stage == .close)
        #expect(auth.identity.closeCode == 1008)
        #expect(auth.message.hasPrefix("Request had invalid authentication credentials"))

        let model = GeminiFailureClassifier.classify(closeCode: 1008, reason: "The requested model is not found for this API version.", source: source)
        #expect(model.category == .configuration && model.disposition == .permanent)
        #expect(GeminiFailureClassifier.classify(closeCode: 1008, reason: nil, source: source).category == .configuration)
        #expect(GeminiFailureClassifier.classify(closeCode: 1008, reason: "", source: source).category == .configuration)
    }

    @Test func otherClosesStayTemporaryWhateverTheReasonSays() {
        for code in [1000, 1001, 1006] {
            let failure = GeminiFailureClassifier.classify(closeCode: code, reason: nil, source: source)
            #expect(failure.category == .disconnected && failure.disposition == .temporary)
        }
        let internalError = GeminiFailureClassifier.classify(closeCode: 1011, reason: "invalid authentication credentials", source: source)
        #expect(internalError.category == .unavailable && internalError.disposition == .temporary)
    }

    /// The close reason is server-supplied text; redaction, not silence, is what keeps a key out.
    @Test func reasonTextIsRedacted() {
        let failure = GeminiFailureClassifier.classify(closeCode: 1008, reason: "bad key AIzaSyExample1234 for ?key=AIzaSyExample1234", source: source)
        #expect(!failure.message.contains("AIzaSyExample"))
    }
}
