import Testing
@testable import JarvisCore

@Suite struct ConfigTests {
    @Test func defaults() {
        let c = Config.default
        #expect(c.silenceTimeoutSeconds == 8)
        #expect(c.cooldownSeconds == 12)
        #expect(c.maxInterjectionsPerMinute == 4)
        #expect(c.transcriptWindowSeconds == 90)
        #expect(c.sentenceDisplaySeconds == 5)
        #expect(c.maxSentences == 3)
        #expect(c.brainModel == "gpt-5.5")
        #expect(c.reasoningEffort == "low")
        #expect(c.transcriptionModel == "gpt-4o-transcribe")
        #expect(c.vadSilenceDurationMs == 1000)
        #expect(c.turnDebounceSeconds == 0.4)
        #expect(c.maxDirectAddressesPerMinute == 8)
        #expect(c.maxBufferedAudioSeconds == 60)
    }

    @Test func envSecretStoreReadsKey() {
        let store = EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-test"])
        #expect(store.apiKey() == "sk-test")
    }

    @Test func envSecretStoreMissingKey() {
        let store = EnvSecretStore(environment: [:])
        #expect(store.apiKey() == nil)
    }
}
