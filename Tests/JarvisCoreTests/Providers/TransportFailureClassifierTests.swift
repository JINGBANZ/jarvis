import Foundation
import Testing
@testable import JarvisCore

@Suite struct TransportFailureClassifierTests {
    /// The description table is fixed text keyed on the code. A URLError's own description embeds
    /// the failing URL, which for Gemini carries the API key, so it is never consulted.
    @Test func urlErrorsGetFixedDescriptionsAndKeepTheirCode() {
        let error = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "wss://generativelanguage.googleapis.com/ws?key=AIzaSecretKey123",
        ])
        let failure = TransportFailureClassifier.classify(
            error: error, source: .transcription(.gemini), everReady: false)
        #expect(failure.stage == .connect)
        #expect(failure.category == .unreachable)
        #expect(failure.disposition == .temporary)
        #expect(failure.identity.transportDomain == NSURLErrorDomain)
        #expect(failure.identity.transportCode == -1004)
        #expect(failure.message == "could not connect to the server")
        #expect(!failure.message.contains("AIza"))
    }

    @Test func aDropAfterReadyIsDisconnectedAndATimeoutIsATimeout() {
        let lost = TransportFailureClassifier.classify(
            error: URLError(.networkConnectionLost), source: .transcription(.openAI), everReady: true)
        #expect(lost.stage == .transport)
        #expect(lost.category == .disconnected)
        #expect(lost.message == "the network connection was lost")

        let timedOut = TransportFailureClassifier.classify(
            error: URLError(.timedOut), source: .brain(.openAI), everReady: false)
        #expect(timedOut.category == .timeout)
        #expect(timedOut.message == "the request timed out")
    }

    @Test func posixErrorsAreCovered() {
        let reset = NSError(domain: NSPOSIXErrorDomain, code: 54)
        let failure = TransportFailureClassifier.classify(
            error: reset, source: .transcription(.openAI), everReady: true)
        #expect(failure.identity.transportDomain == NSPOSIXErrorDomain)
        #expect(failure.message == "connection reset by peer")
        #expect(TransportFailureClassifier.description(domain: NSPOSIXErrorDomain, code: 57)
                == "socket is not connected")
        #expect(TransportFailureClassifier.description(domain: "Other", code: 9) == "Other error 9")
    }

    @Test func readinessAndLivenessTimeoutsAreNamed() {
        let never = TransportFailureClassifier.readinessTimeout(
            seconds: 10, source: .transcription(.openAI), everReady: false)
        #expect(never.stage == .readiness)
        #expect(never.category == .unreachable)
        #expect(never.message == "no session acknowledgement within 10s")

        let again = TransportFailureClassifier.readinessTimeout(
            seconds: 10, source: .transcription(.openAI), everReady: true)
        #expect(again.category == .disconnected)

        let pong = TransportFailureClassifier.livenessTimeout(seconds: 10, source: .transcription(.gemini))
        #expect(pong.stage == .liveness)
        #expect(pong.category == .disconnected)
        #expect(pong.message == "no pong within 10s")
    }

    /// This table is shared by the brain HTTP adapter and the credential check, neither of which has
    /// a socket, so no description here may name one. The row is the diagnostic surface, and a wrong
    /// noun on it costs exactly the evidence it exists to give.
    @Test func descriptionsNameNothingCallerSpecific() {
        #expect(TransportFailureClassifier.description(domain: NSURLErrorDomain, code: -1011)
                == "the server sent an unusable response")
        let request = TransportFailureClassifier.classify(
            error: URLError(.badServerResponse), source: .brain(.openAI), everReady: false)
        #expect(!request.message.contains("WebSocket"))
        #expect(!request.message.contains("socket"))
    }

    @Test func transportDomainsAreRecognized() {
        #expect(TransportFailureClassifier.isTransportDomain(NSURLErrorDomain))
        #expect(TransportFailureClassifier.isTransportDomain(NSPOSIXErrorDomain))
        #expect(!TransportFailureClassifier.isTransportDomain("CLIBrainClient"))
    }
}
