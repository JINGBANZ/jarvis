import Testing
@testable import JarvisCore

@Suite struct ConfigTests {
    @Test func defaults() {
        let c = Config.default
        #expect(c.silenceTimeoutSeconds == 30)
        #expect(c.silenceMaxIntervalSeconds == 240)
        #expect(c.transcriptWindowSeconds == 90)
        #expect(c.lineDisplaySeconds == 5)
        #expect(c.brainModel == "gpt-5.5")
        #expect(c.reasoningEffort == "low")
        #expect(c.transcriptionModel == "gpt-4o-transcribe")
        #expect(c.vadSilenceDurationMs == 1000)
        #expect(c.turnDebounceSeconds == 0.4)
        #expect(c.maxBufferedAudioSeconds == 60)
    }

    @Test func overlayAppearanceConstants() {
        #expect(Config.overlayFontSizeDefault == 18)
        #expect(Config.overlayFontSizeRange == 12...32)
        #expect(Config.overlayOpacityDefault == 0.78)
        #expect(Config.overlayOpacityRange == 0.40...1.0)
    }

    /// Invariants the rest of the code relies on, independent of the exact literals above:
    /// each default must sit inside its range, and each range must be non-empty.
    @Test func overlayAppearanceConstantsAreCoherent() {
        #expect(Config.overlayFontSizeRange.contains(Config.overlayFontSizeDefault))
        #expect(Config.overlayOpacityRange.contains(Config.overlayOpacityDefault))
        #expect(Config.overlayFontSizeRange.lowerBound < Config.overlayFontSizeRange.upperBound)
        #expect(Config.overlayOpacityRange.lowerBound < Config.overlayOpacityRange.upperBound)
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
