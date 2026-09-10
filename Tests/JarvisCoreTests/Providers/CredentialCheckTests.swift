import Foundation
import Testing
@testable import JarvisCore

@Suite struct CredentialCheckTests {
    @Test func acceptsAnyTwoHundred() {
        #expect(CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 200, body: Data()) == .accepted)
        #expect(CredentialCheck.verdict(for: .geminiAPIKey, httpStatus: 200, body: nil) == .accepted)
    }

    /// The verdict is the vendor's own table, not a second opinion about status codes, so Settings
    /// and a failed session agree about what a key did.
    @Test func rejectionsUseTheVendorTable() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "invalid_api_key", "type": "invalid_request_error",
                      "message": "Incorrect API key provided: sk-abc12345"],
        ])
        guard case .rejected(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 401, body: body) else {
            Issue.record("expected rejection"); return
        }
        #expect(failure.source == .brain(.openAI))
        #expect(failure.category == .authentication)
        #expect(CredentialCheck.statusText(.rejected(failure), for: .openAIAPIKey)
                == "OpenAI refused the key (HTTP 401, invalid_api_key: Incorrect API key provided: sk-…).")

        let google = try JSONSerialization.data(withJSONObject: [
            "error": ["status": "INVALID_ARGUMENT", "message": "API key not valid.",
                      "details": [["reason": "API_KEY_INVALID"]]],
        ])
        guard case .rejected(let gemini) =
            CredentialCheck.verdict(for: .geminiAPIKey, httpStatus: 400, body: google) else {
            Issue.record("expected rejection"); return
        }
        #expect(gemini.category == .authentication)
        #expect(gemini.source == .transcription(.gemini))
        #expect(CredentialCheck.statusText(.rejected(gemini), for: .geminiAPIKey)
                == "Gemini refused the key (HTTP 400, API_KEY_INVALID: API key not valid.).")
    }

    /// A 5xx is not a verdict on the key.
    @Test func serverTroubleIsUnreachableNotRejected() {
        guard case .unreachable(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 503, body: nil) else {
            Issue.record("expected unreachable"); return
        }
        #expect(failure.category == .unavailable)
        #expect(CredentialCheck.statusText(.unreachable(failure), for: .openAIAPIKey)
                == "I couldn't reach OpenAI (HTTP 503).")
    }

    @Test func transportErrorsAreUnreachable() {
        guard case .unreachable(let failure) = CredentialCheck.verdict(
            for: .openAIAPIKey, transportError: URLError(.notConnectedToInternet)) else {
            Issue.record("expected unreachable"); return
        }
        #expect(CredentialCheck.statusText(.unreachable(failure), for: .openAIAPIKey)
                == "I couldn't reach OpenAI (network -1009: the internet connection appears to be offline).")
        #expect(CredentialCheck.statusText(.accepted, for: .geminiAPIKey) == "Gemini accepted the key.")
    }

    /// The verdict line is provider text like any other, so a key echoed back in a message is masked
    /// before it can be rendered under the field the user just typed it into.
    @Test func theVerdictNeverEchoesTheKey() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "invalid_api_key",
                      "message": "Incorrect API key provided: sk-live-9f3ab27c. Rotate it."],
        ])
        guard case .rejected(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 401, body: body) else {
            Issue.record("expected rejection"); return
        }
        let text = CredentialCheck.statusText(.rejected(failure), for: .openAIAPIKey)
        #expect(!text.contains("sk-live-9f3ab27c"))
        #expect(text.contains("sk-…"))
    }
}
