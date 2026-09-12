import Foundation
import Testing
@testable import JarvisCore

@Suite struct OpenAIFailureClassifierTests {
    /// `<type>.<code>` is the documented shape, but a reason arriving as a bare code still names a
    /// rejection. Reading it as a transport close spent the whole retry budget on a refused key.
    @Test func aDotlessCloseReasonIsStillAnErrorCode() {
        let failure = OpenAIFailureClassifier.classify(
            closeCode: 3000, reason: "invalid_api_key", source: .transcription(.openAI))
        #expect(failure.category == .authentication)
        #expect(failure.disposition == .permanent)
        #expect(failure.identity.errorCode == "invalid_api_key")
        #expect(failure.identity.errorType == nil)
    }

    /// An unrecognized dotless reason is still the server refusing, so the row quotes what it said
    /// rather than claiming the connection was merely lost. It stays temporary either way.
    @Test func anUnrecognizedDotlessCloseReasonIsQuotedAsARejection() {
        let failure = OpenAIFailureClassifier.classify(
            closeCode: 3000, reason: "session ended by policy", source: .transcription(.openAI))
        #expect(failure.category == .rejected)
        #expect(failure.disposition == .temporary)
        #expect(failure.message == "session ended by policy")
    }

    /// An empty reason has nothing to read, so 3000 falls through to the transport path.
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

    /// Mirrors the brain adapter's proof: only authentication, billing, and access statuses are
    /// permanent on a plain request; request-local and unknown 4xx stay temporary.
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
        let auth = OpenAIFailureClassifier.classify(httpStatus: 429, body: body(type: "authentication_error"), source: brain, stage: .request)
        #expect(auth.category == .authentication && auth.disposition == .permanent)
        let region = OpenAIFailureClassifier.classify(httpStatus: 403, body: body(code: "unsupported_country_region_territory", type: "request_forbidden"), source: transcription, stage: .handshake)
        #expect(region.category == .access && region.disposition == .permanent)
    }

    /// A refused WebSocket upgrade has no body to read, so the status is the whole evidence. It is
    /// permanent only where the status itself says the request cannot succeed as sent; a status that
    /// describes a moment keeps the bounded first-connect budget rather than ending the session on
    /// the first attempt.
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

    /// An edge or proxy answering a WebSocket upgrade with a timeout is a moment, not a contract.
    /// Marking it permanent ended the whole session on the first attempt, spending none of the
    /// three-attempt budget that exists precisely for a connection that has not come up yet.
    @Test func transientHandshakeStatusesKeepTheirRetries() {
        for status in [408, 409, 423, 425] {
            let failure = OpenAIFailureClassifier.classify(
                httpStatus: status, body: nil, source: transcription, stage: .handshake)
            #expect(failure.disposition == .temporary, "HTTP \(status) at a handshake must stay retryable")
            #expect(!failure.endsEverySession)
        }
        // The same status on a plain request was always temporary and stays so.
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
        // Utterance-local and transient errors stay temporary so one bad item never ends a session.
        #expect(OpenAIFailureClassifier.classify(event: event(failed, code: "audio_unintelligible"), source: transcription)?.disposition == .temporary)
        #expect(OpenAIFailureClassifier.classify(event: event(failed, code: "rate_limit_exceeded"), source: transcription)?.disposition == .temporary)
        #expect(OpenAIFailureClassifier.classify(event: event("error", code: "invalid_value", param: "item.audio"), source: transcription)?.disposition == .temporary)
        #expect(OpenAIFailureClassifier.classify(event: event(RealtimeSession.completedTranscriptionType, code: "insufficient_quota"), source: transcription) == nil)
        #expect(OpenAIFailureClassifier.classify(event: ["type": failed], source: transcription) == nil)
        let stage = OpenAIFailureClassifier.classify(event: event("error", code: "invalid_api_key"), source: transcription)
        #expect(stage?.stage == .session)
        #expect(stage?.identity.errorCode == "invalid_api_key")
    }

    /// Captured 2026-09-08 with a throwaway key: OpenAI accepts the upgrade, sends the error event,
    /// then closes with code 3000 and reason "invalid_request_error.invalid_api_key".
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
