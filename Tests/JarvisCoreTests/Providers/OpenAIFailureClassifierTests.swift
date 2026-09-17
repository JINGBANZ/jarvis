import Foundation
import Testing
@testable import JarvisCore

@Suite struct OpenAIFailureClassifierTests {
    /// The documented reason shape is <type>.<code>, but a bare code still names a rejection.
    @Test func aDotlessCloseReasonIsStillAnErrorCode() {
        let failure = OpenAIFailureClassifier.classify(
            closeCode: 3000, reason: "invalid_api_key", source: .transcription(.openAI))
        #expect(failure.category == .authentication)
        #expect(failure.disposition == .permanent)
        #expect(failure.identity.errorCode == "invalid_api_key")
        #expect(failure.identity.errorType == nil)
    }

    @Test func anUnrecognizedDotlessCloseReasonIsQuotedAsARejection() {
        let failure = OpenAIFailureClassifier.classify(
            closeCode: 3000, reason: "session ended by policy", source: .transcription(.openAI))
        #expect(failure.category == .rejected)
        #expect(failure.disposition == .temporary)
        #expect(failure.message == "session ended by policy")
        #expect(failure.identity.errorCode == nil)
        #expect(failure.identity == .init(closeCode: 3000))
        #expect(failure.activityDetail == " (close 3000: session ended by policy)")
    }

    @Test func aCredentialInACloseReasonNeverReachesTheRow() {
        let prose = OpenAIFailureClassifier.classify(
            closeCode: 3000, reason: "rejected: key sk-live-9f3ab27c is invalid",
            source: .transcription(.openAI))
        #expect(!prose.identity.summary.contains("sk-live-9f3ab27c"))
        #expect(!prose.activitySentence.contains("sk-live-9f3ab27c"))
        #expect(prose.activitySentence.contains("sk-…"))

        // A bare token passes the identifier guard, so only the record's redaction stops it.
        let bare = ProviderFailure(
            source: .transcription(.openAI), stage: .close, category: .rejected,
            disposition: .temporary,
            identity: .init(closeCode: 3000, errorType: "sk-live-9f3ab27c", errorCode: "AIzaSyRealKey123"),
            message: "")
        #expect(bare.identity.errorType == "sk-…")
        #expect(bare.identity.errorCode == "AIza…")
        #expect(!bare.identity.summary.contains("AIzaSyRealKey123"))
        #expect(bare.activitySentence == "OpenAI refused the transcription request (close 3000, AIza…)")
    }

    @Test func anEmptyCloseReasonStaysTransport() {
        let failure = OpenAIFailureClassifier.classify(
            closeCode: 3000, reason: "  ", source: .transcription(.openAI))
        #expect(failure.category == .disconnected)
        #expect(failure.message == "closed with code 3000")
    }

    private let brain = ProviderFailure.Source.brain(.openAI)
    private let transcription = ProviderFailure.Source.transcription(.openAI)

    private func body(code: String? = nil, type: String? = nil, param: String? = nil,
                      message: String = "m") -> Data {
        var error: [String: Any] = ["message": message]
        if let code { error["code"] = code }
        if let type { error["type"] = type }
        if let param { error["param"] = param }
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    @Test func requestStatusesFollowTheBrainTable() {
        for status in [408, 409, 500, 503, 599] {
            #expect(OpenAIFailureClassifier.classify(httpStatus: status, body: nil, source: brain, stage: .request).disposition == .temporary)
        }
        for status in [400, 404, 418, 422] {
            let failure = OpenAIFailureClassifier.classify(httpStatus: status, body: nil, source: brain, stage: .request)
            #expect(failure.disposition == .temporary)
            #expect(failure.category == .rejected)
        }
        let unauthorized = OpenAIFailureClassifier.classify(
            httpStatus: 401, body: body(code: "invalid_api_key", type: "invalid_request_error",
                                         message: "Incorrect API key provided: sk-abc12345"),
            source: brain, stage: .request)
        #expect(unauthorized.category == .authentication)
        #expect(unauthorized.disposition == .permanent)
        #expect(unauthorized.identity == .init(httpStatus: 401, errorType: "invalid_request_error", errorCode: "invalid_api_key"))
        #expect(unauthorized.message == "Incorrect API key provided: sk-…")
        #expect(OpenAIFailureClassifier.classify(httpStatus: 402, body: nil, source: brain, stage: .request).category == .quota)
        #expect(OpenAIFailureClassifier.classify(httpStatus: 403, body: nil, source: brain, stage: .request).category == .access)
        #expect(OpenAIFailureClassifier.classify(httpStatus: 500, body: nil, source: brain, stage: .request).category == .unavailable)
    }

    @Test func codesAndTypesOutrankStatuses() {
        let quota = OpenAIFailureClassifier.classify(httpStatus: 429, body: body(code: "insufficient_quota"), source: brain, stage: .request)
        #expect(quota.category == .quota && quota.disposition == .permanent)
        let rate = OpenAIFailureClassifier.classify(httpStatus: 429, body: body(code: "rate_limit_exceeded"), source: brain, stage: .request)
        #expect(rate.category == .rejected && rate.disposition == .temporary)
        let model = OpenAIFailureClassifier.classify(httpStatus: 404, body: body(code: "model_not_found"), source: brain, stage: .request)
        #expect(model.category == .configuration && model.disposition == .permanent)
        // CLIProxyAPI returns this once every credential for the model's vendor is gone.
        let signedOut = OpenAIFailureClassifier.classify(httpStatus: 503, body: body(code: "upstream_authentication_required"), source: brain, stage: .request)
        #expect(signedOut.category == .authentication && signedOut.disposition == .permanent)
        let auth = OpenAIFailureClassifier.classify(httpStatus: 429, body: body(type: "authentication_error"), source: brain, stage: .request)
        #expect(auth.category == .authentication && auth.disposition == .permanent)
        let region = OpenAIFailureClassifier.classify(httpStatus: 403, body: body(code: "unsupported_country_region_territory", type: "request_forbidden"), source: transcription, stage: .handshake)
        #expect(region.category == .access && region.disposition == .permanent)
    }

    @Test func refusedHandshakesArePermanentOnlyWhereTheStatusProvesIt() {
        let forbidden = OpenAIFailureClassifier.classify(httpStatus: 403, body: nil, source: transcription, stage: .handshake)
        #expect(forbidden.category == .access && forbidden.disposition == .permanent && forbidden.stage == .handshake)
        let notFound = OpenAIFailureClassifier.classify(httpStatus: 404, body: nil, source: transcription, stage: .handshake)
        #expect(notFound.category == .rejected && notFound.disposition == .permanent)
        let malformed = OpenAIFailureClassifier.classify(httpStatus: 400, body: nil, source: transcription, stage: .handshake)
        #expect(malformed.disposition == .permanent)
        let limited = OpenAIFailureClassifier.classify(httpStatus: 429, body: nil, source: transcription, stage: .handshake)
        #expect(limited.disposition == .temporary)
        let down = OpenAIFailureClassifier.classify(httpStatus: 503, body: nil, source: transcription, stage: .handshake)
        #expect(down.category == .unavailable && down.disposition == .temporary)
    }

    @Test func transientHandshakeStatusesKeepTheirRetries() {
        for status in [408, 409, 423, 425] {
            let failure = OpenAIFailureClassifier.classify(
                httpStatus: status, body: nil, source: transcription, stage: .handshake)
            #expect(failure.disposition == .temporary, "HTTP \(status) at a handshake must stay retryable")
            #expect(!failure.endsEverySession)
        }
        let request = OpenAIFailureClassifier.classify(
            httpStatus: 408, body: nil, source: .brain(.openAI), stage: .request)
        #expect(request.disposition == .temporary)
    }

    @Test func inBandEventsClassifyBreakingAccountErrors() {
        func event(_ type: String, code: String? = nil, errorType: String? = nil, param: String? = nil) -> [String: Any] {
            var error: [String: Any] = ["message": "m"]
            if let code { error["code"] = code }
            if let errorType { error["type"] = errorType }
            if let param { error["param"] = param }
            return ["type": type, "error": error]
        }
        let failed = RealtimeSession.failedTranscriptionType
        #expect(OpenAIFailureClassifier.classify(event: event(failed, code: "insufficient_quota"), source: transcription)?.category == .quota)
        #expect(OpenAIFailureClassifier.classify(event: event(failed, code: "invalid_api_key"), source: transcription)?.disposition == .permanent)
        #expect(OpenAIFailureClassifier.classify(event: event(failed, errorType: "permission_error"), source: transcription)?.category == .access)
        #expect(OpenAIFailureClassifier.classify(event: event("error", code: "invalid_value", param: "session.audio.input.turn_detection"), source: transcription)?.category == .configuration)
        #expect(OpenAIFailureClassifier.classify(event: event(failed, code: "audio_unintelligible"), source: transcription)?.disposition == .temporary)
        #expect(OpenAIFailureClassifier.classify(event: event(failed, code: "rate_limit_exceeded"), source: transcription)?.disposition == .temporary)
        #expect(OpenAIFailureClassifier.classify(event: event("error", code: "invalid_value", param: "item.audio"), source: transcription)?.disposition == .temporary)
        #expect(OpenAIFailureClassifier.classify(event: event(RealtimeSession.completedTranscriptionType, code: "insufficient_quota"), source: transcription) == nil)
        #expect(OpenAIFailureClassifier.classify(event: ["type": failed], source: transcription) == nil)
        let stage = OpenAIFailureClassifier.classify(event: event("error", code: "invalid_api_key"), source: transcription)
        #expect(stage?.stage == .session)
        #expect(stage?.identity.errorCode == "invalid_api_key")
    }

    /// Real capture: OpenAI rejects a bad key with close 3000 and a type.code reason.
    @Test func closeReasonsCarryTypeDotCode() {
        let rejected = OpenAIFailureClassifier.classify(closeCode: 3000, reason: "invalid_request_error.invalid_api_key", source: transcription)
        #expect(rejected.stage == .close)
        #expect(rejected.category == .authentication)
        #expect(rejected.disposition == .permanent)
        #expect(rejected.identity == .init(closeCode: 3000, errorType: "invalid_request_error", errorCode: "invalid_api_key"))

        let unknown = OpenAIFailureClassifier.classify(closeCode: 3000, reason: "invalid_request_error.insufficient_permissions", source: transcription)
        #expect(unknown.category == .rejected)
        #expect(unknown.disposition == .temporary)
        #expect(unknown.identity.errorCode == "insufficient_permissions")

        let away = OpenAIFailureClassifier.classify(closeCode: 1001, reason: nil, source: transcription)
        #expect(away.category == .disconnected && away.disposition == .temporary)
        #expect(away.message == "server going away")
        let abnormal = OpenAIFailureClassifier.classify(closeCode: 1006, reason: "", source: transcription)
        #expect(abnormal.message == "closed with code 1006")
    }
}
