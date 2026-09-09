import Testing
@testable import JarvisCore

@Suite struct ProviderMessageRedactionTests {
    /// The exact wording OpenAI returned for a bad key on 2026-09-08 (captured with a throwaway key).
    @Test func masksOpenAIKeyFragments() {
        let raw = "Incorrect API key provided: sk-inval***********-000. You can find your API key at https://platform.openai.com/account/api-keys."
        let redacted = ProviderMessageRedaction.redact(raw)
        #expect(!redacted.contains("sk-inval"))
        #expect(redacted.contains("sk-…"))
        #expect(redacted.contains("Incorrect API key provided"))
    }

    @Test func masksGoogleKeysAndKeyQueryParameters() {
        let raw = "connect wss://generativelanguage.googleapis.com/ws/x?key=AIzaSyD-example-key-1234 failed; header x-goog-api-key: AIzaSyD-example-key-1234"
        let redacted = ProviderMessageRedaction.redact(raw)
        #expect(!redacted.contains("AIzaSyD"))
        #expect(redacted.contains("key=…"))
    }

    @Test func masksBearerTokens() {
        let redacted = ProviderMessageRedaction.redact("rejected Authorization: Bearer abc.def-ghi")
        #expect(!redacted.contains("abc.def-ghi"))
        #expect(redacted.contains("Bearer …"))
    }

    @Test func collapsesWhitespaceAndCapsLength() {
        let raw = "line one\n\n   line two " + String(repeating: "x", count: 400)
        let redacted = ProviderMessageRedaction.redact(raw)
        #expect(redacted.hasPrefix("line one line two"))
        #expect(redacted.count <= ProviderMessageRedaction.maximumLength)
        #expect(redacted.hasSuffix("…"))
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(ProviderMessageRedaction.redact("Country, region, or territory not supported")
                == "Country, region, or territory not supported")
        #expect(ProviderMessageRedaction.redact("   ") == "")
    }
}
