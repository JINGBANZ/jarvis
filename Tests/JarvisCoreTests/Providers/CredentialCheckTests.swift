import Foundation
import Testing
@testable import JarvisCore

@Suite struct CredentialCheckTests {
    @Test func acceptsAnyTwoHundred() {
        #expect(CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 200, body: Data()) == .accepted)
        #expect(CredentialCheck.verdict(for: .geminiAPIKey, httpStatus: 200, body: nil) == .accepted)
    }

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

    @Test func serverTroubleIsInconclusiveNotRejected() {
        guard case .inconclusive(let failure) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 503, body: nil) else {
            Issue.record("expected inconclusive"); return
        }
        #expect(failure.category == .unavailable)
        #expect(CredentialCheck.statusText(.inconclusive(failure), for: .openAIAPIKey)
                == "I couldn't check the key with OpenAI (HTTP 503).")
    }

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

    @Test func permanentFailuresThatAreNotAboutTheKeyStayInconclusive() throws {
        let noCredit = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "insufficient_quota", "type": "insufficient_quota",
                      "message": "You exceeded your current quota, please check your plan and billing details."],
        ])
        guard case .inconclusive(let quota) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 429, body: noCredit) else {
            Issue.record("expected inconclusive"); return
        }
        // Permanent for a live session, yet the saved key is still valid.
        #expect(quota.disposition == .permanent)
        #expect(quota.category == .quota)
        #expect(CredentialCheck.statusText(.inconclusive(quota), for: .openAIAPIKey)
                == "I couldn't check the key with OpenAI (HTTP 429, insufficient_quota: You exceeded your current quota, please check your plan and billing details.).")

        let forbidden = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "unsupported_country_region_territory",
                      "message": "Country, region, or territory not supported"],
        ])
        guard case .inconclusive(let region) =
            CredentialCheck.verdict(for: .openAIAPIKey, httpStatus: 403, body: forbidden) else {
            Issue.record("expected inconclusive"); return
        }
        #expect(region.category == .access)
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
