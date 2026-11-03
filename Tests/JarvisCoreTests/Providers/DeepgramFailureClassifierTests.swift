import Foundation
import Testing
@testable import JarvisCore

@Suite struct DeepgramFailureClassifierTests {
    private let source = ProviderFailure.Source.transcription(.deepgram)

    private func classify(_ status: Int, body: String? = nil, stage: ProviderFailure.Stage = .request) -> ProviderFailure {
        DeepgramFailureClassifier.classify(
            httpStatus: status, body: body.map { Data($0.utf8) }, source: source, stage: stage)
    }

    @Test func aRejectedKeyIsPermanentAuthentication() {
        let failure = classify(401, body: #"{"err_code":"INVALID_AUTH","err_msg":"Invalid credentials."}"#)
        #expect(failure.category == .authentication && failure.disposition == .permanent)
        #expect(failure.identity == .init(httpStatus: 401, errorCode: "INVALID_AUTH"))
        #expect(failure.message == "Invalid credentials.")
    }

    @Test func statusesMapToCategories() {
        #expect(classify(402).category == .quota && classify(402).disposition == .permanent)
        #expect(classify(403).category == .access && classify(403).disposition == .permanent)
        #expect(classify(429).category == .quota && classify(429).disposition == .temporary)
        #expect(classify(503).category == .unavailable && classify(503).disposition == .temporary)
        #expect(classify(302).category == .unknown && classify(302).disposition == .temporary)
    }

    @Test func aMalformedUpgradeIsPermanentOnlyAtTheHandshake() {
        #expect(classify(400, stage: .handshake).disposition == .permanent)
        #expect(classify(400, stage: .request).disposition == .temporary)
    }

    @Test func quotesABodyThatIsNotDeepgramJSON() {
        let failure = classify(502, body: "upstream connect error")
        #expect(failure.message == "upstream connect error")
    }

    @Test func closeCodesNeverProveABadKey() {
        let bad = DeepgramFailureClassifier.classify(closeCode: 1008, reason: nil, source: source)
        #expect(bad.category == .rejected && bad.disposition == .temporary)
        let fault = DeepgramFailureClassifier.classify(closeCode: 1011, reason: "NET-0001", source: source)
        #expect(fault.category == .unavailable && fault.message == "NET-0001")
        let other = DeepgramFailureClassifier.classify(closeCode: 1006, reason: nil, source: source)
        #expect(other.category == .disconnected && other.disposition == .temporary)
    }
}
