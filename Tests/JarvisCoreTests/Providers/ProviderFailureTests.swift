import Foundation
import Testing
@testable import JarvisCore

@Suite struct ProviderFailureTests {
    private func failure(
        stage: ProviderFailure.Stage,
        category: ProviderFailure.Category,
        disposition: ProviderFailure.Disposition
    ) -> ProviderFailure {
        ProviderFailure(
            source: .transcription(.openAI), stage: stage, category: category,
            disposition: disposition, identity: .init(), message: "")
    }

    @Test func initRedactsTheMessage() {
        let failure = ProviderFailure(
            source: .brain(.openAI), stage: .request, category: .authentication,
            disposition: .permanent, identity: .init(httpStatus: 401, errorCode: "invalid_api_key"),
            message: "Incorrect API key provided: sk-abc123456789")
        #expect(failure.message == "Incorrect API key provided: sk-…")
        #expect(failure.errorDescription == "HTTP 401, invalid_api_key: Incorrect API key provided: sk-…")
    }

    @Test func identitySummaryNamesWhatIsKnown() {
        #expect(ProviderFailure.Identity(httpStatus: 403, errorCode: "unsupported_country_region_territory").summary
                == "HTTP 403, unsupported_country_region_territory")
        #expect(ProviderFailure.Identity(closeCode: 3000, errorCode: "insufficient_permissions").summary
                == "close 3000, insufficient_permissions")
        #expect(ProviderFailure.Identity(transportDomain: "NSURLErrorDomain", transportCode: -1004).summary
                == "network -1004")
        #expect(ProviderFailure.Identity(exitStatus: 1).summary == "exit 1")
        #expect(ProviderFailure.Identity(errorType: "invalid_request_error").summary == "invalid_request_error")
        #expect(ProviderFailure.Identity().summary == "")
    }

    /// Adapters hand errors nothing has classified through this initializer. It keeps the NSError
    /// identity, never trusts the description with a URL, and stays temporary.
    @Test func unclassifiedErrorsKeepDomainAndCodeAndStayTemporary() {
        let error = NSError(domain: "CLIBrainClient", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "app-server unavailable"])
        let failure = ProviderFailure(unclassified: error, source: .brain(.codexCLI), stage: .request)
        #expect(failure.disposition == .temporary)
        #expect(failure.category == .unknown)
        #expect(failure.identity.transportDomain == "CLIBrainClient")
        #expect(failure.identity.transportCode == 1)
        #expect(failure.message == "app-server unavailable")

        let url = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "wss://example.test/ws?key=AIzaSecret12345",
        ])
        let transport = ProviderFailure(unclassified: url, source: .transcription(.gemini), stage: .connect)
        #expect(transport.identity.transportCode == URLError.cannotConnectToHost.rawValue)
        #expect(!transport.message.contains("AIzaSecret"))
        #expect(!transport.message.contains("example.test"))
    }

    /// A permanent account, access, or configuration failure and a connection that never came up
    /// are shared by both transcription sockets (same key, same network), so a system-audio-side
    /// failure of that kind ends the session instead of hiding behind a mic-only degradation that
    /// the mic socket then repeats seconds later. Local failures (Apple Speech, capture) and a
    /// socket lost after it was ready stay stream-local.
    @Test func endsEverySessionFollowsStageAndDisposition() {
        #expect(failure(stage: .handshake, category: .access, disposition: .permanent).endsEverySession)
        #expect(failure(stage: .session, category: .authentication, disposition: .permanent).endsEverySession)
        #expect(failure(stage: .connect, category: .unreachable, disposition: .temporary).endsEverySession)
        #expect(failure(stage: .readiness, category: .unreachable, disposition: .temporary).endsEverySession)
        #expect(!failure(stage: .close, category: .disconnected, disposition: .temporary).endsEverySession)
        #expect(!failure(stage: .liveness, category: .disconnected, disposition: .temporary).endsEverySession)
        #expect(!failure(stage: .local, category: .unavailable, disposition: .permanent).endsEverySession)
    }

    /// Every category has an explicit escalate-or-degrade answer for both dispositions so a future
    /// category cannot default silently.
    @Test func everyCategoryHasAnExplicitDecision() {
        let escalatesWhenTemporary: Set<ProviderFailure.Category> = [.unreachable]
        for category in ProviderFailure.Category.allCases {
            #expect(failure(stage: .session, category: category, disposition: .temporary).endsEverySession
                    == escalatesWhenTemporary.contains(category))
            #expect(failure(stage: .session, category: category, disposition: .permanent).endsEverySession)
        }
    }
}
