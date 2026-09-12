import Foundation
import Testing
@testable import JarvisCore

@Suite struct ProviderFailureExhaustionTests {
    private let source = ProviderFailure.Source.transcription(.openAI)

    /// The bug this whole change exists for: a socket that never reached ready spends its budget and
    /// the session must say what kept refusing it, not "the connection was lost".
    @Test func aBudgetSpentBeforeReadyKeepsTheCauseAndEscalates() {
        let refused = ProviderFailure(
            source: source, stage: .connect, category: .unreachable, disposition: .temporary,
            identity: .init(transportDomain: NSURLErrorDomain, transportCode: -1004),
            message: "could not connect to the server")
        let exhausted = ProviderFailure.exhausted(last: refused, source: source, everReady: false)

        #expect(exhausted.category == .unreachable)
        #expect(exhausted.stage == .connect)
        #expect(exhausted.identity == refused.identity)
        #expect(exhausted.message == "could not connect to the server")
        #expect(exhausted.endsEverySession)
        #expect(exhausted.activitySentence
                == "OpenAI couldn't be reached for transcription (network -1004: could not connect to the server); check your network or VPN")
    }

    /// A socket lost after it was ready stays a blip local to that one stream, so the system-audio
    /// side degrades to microphone-only instead of ending the session.
    @Test func aBudgetSpentAfterReadyStaysStreamLocal() {
        let dropped = ProviderFailure(
            source: source, stage: .close, category: .disconnected, disposition: .temporary,
            identity: .init(closeCode: 1006), message: "")
        let exhausted = ProviderFailure.exhausted(last: dropped, source: source, everReady: true)

        #expect(exhausted.category == .disconnected)
        #expect(exhausted.stage == .close)
        #expect(!exhausted.endsEverySession)
        #expect(exhausted.activitySentence
                == "the transcription connection to OpenAI was lost (close 1006)")
    }

    /// The last cause's own category is discarded: what matters when a budget runs out is whether
    /// the socket was ever ready, not how the final attempt happened to fail.
    @Test func theCategoryComesFromReadinessNotTheLastCause() {
        let timedOut = ProviderFailure(
            source: source, stage: .readiness, category: .disconnected, disposition: .temporary,
            identity: .init(), message: "no session acknowledgement within 10s")
        #expect(ProviderFailure.exhausted(last: timedOut, source: source, everReady: false).category
                == .unreachable)
    }

    /// Nothing was ever classified (every attempt failed before a cause could be observed): the row
    /// still names the surface and the direction of the failure.
    @Test func noObservedCauseStillRendersASentence() {
        let never = ProviderFailure.exhausted(last: nil, source: source, everReady: false)
        #expect(never.stage == .connect)
        #expect(never.activitySentence
                == "OpenAI couldn't be reached for transcription; check your network or VPN")

        let lost = ProviderFailure.exhausted(last: nil, source: source, everReady: true)
        #expect(lost.stage == .transport)
        #expect(lost.activitySentence == "the transcription connection to OpenAI was lost")
    }

    /// The carried message goes through the record's redaction like every other quoted provider text.
    @Test func theCarriedMessageStaysRedacted() {
        let leaky = ProviderFailure(
            source: source, stage: .session, category: .rejected, disposition: .temporary,
            identity: .init(), message: "refused: Authorization: Bearer abc123token")
        let exhausted = ProviderFailure.exhausted(last: leaky, source: source, everReady: false)
        #expect(!exhausted.activitySentence.contains("abc123token"))
        #expect(exhausted.activitySentence.contains("Bearer …"))
    }
}
