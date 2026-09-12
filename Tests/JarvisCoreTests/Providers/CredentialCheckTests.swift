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
    @Test func serverTroubleIsInconclusiveNotRejected() {
        guard case .inconclusive(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 503, body: nil) else {
            Issue.record("expected inconclusive"); return
        }
        #expect(failure.category == .unavailable)
        #expect(CredentialCheck.statusText(.inconclusive(failure), for: .openAIAPIKey)
                == "I couldn't check the key with OpenAI (HTTP 503).")
    }

    /// A rate limit reaches the provider and comes back over a connection that plainly worked, but it
    /// says nothing about the key. Calling it a refusal would send a user to rotate a valid key and
    /// hit the same limit on the replacement, so the disposition decides, not the status range.
    @Test func rateLimitsAndExhaustedQuotasAreInconclusive() throws {
        let openAI = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "rate_limit_exceeded", "type": "requests",
                      "message": "Rate limit reached for requests"],
        ])
        guard case .inconclusive(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 429, body: openAI) else {
            Issue.record("expected inconclusive"); return
        }
        #expect(failure.disposition == .temporary)
        #expect(CredentialCheck.statusText(.inconclusive(failure), for: .openAIAPIKey)
                == "I couldn't check the key with OpenAI (HTTP 429, rate_limit_exceeded: Rate limit reached for requests).")

        let google = try JSONSerialization.data(withJSONObject: [
            "error": ["status": "RESOURCE_EXHAUSTED", "message": "Quota exceeded for requests"],
        ])
        guard case .inconclusive(let gemini) =
            CredentialCheck.verdict(for: .geminiAPIKey, httpStatus: 429, body: google) else {
            Issue.record("expected inconclusive"); return
        }
        #expect(gemini.category == .quota)
        #expect(CredentialCheck.statusText(.inconclusive(gemini), for: .geminiAPIKey)
                == "I couldn't check the key with Gemini (HTTP 429, RESOURCE_EXHAUSTED: Quota exceeded for requests).")
    }

    /// A permanent refusal still reads as one, so the fix above cannot swallow a real rejection.
    @Test func permanentRefusalsStayRejections() throws {
        let forbidden = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "unsupported_country_region_territory",
                      "message": "Country, region, or territory not supported"],
        ])
        guard case .rejected(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 403, body: forbidden) else {
            Issue.record("expected rejection"); return
        }
        #expect(failure.disposition == .permanent)
        #expect(failure.category == .access)
    }

    @Test func transportErrorsAreInconclusive() {
        guard case .inconclusive(let failure) = CredentialCheck.verdict(
            for: .openAIAPIKey, transportError: URLError(.notConnectedToInternet)) else {
            Issue.record("expected inconclusive"); return
        }
        #expect(CredentialCheck.statusText(.inconclusive(failure), for: .openAIAPIKey)
                == "I couldn't check the key with OpenAI (network -1009: the internet connection appears to be offline).")
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
