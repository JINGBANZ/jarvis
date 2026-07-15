import Testing
@testable import JarvisCore

@Suite struct ConfigTests {
    @Test func defaults() {
        let c = Config.default
        #expect(c.silenceTimeoutSeconds == 120)
        #expect(c.silenceMaxIntervalSeconds == 960)
        #expect(c.silenceIdleCutoffSeconds == 1_800)
        #expect(c.historyCompactionTokenThreshold == 10_000)
        #expect(c.overlayNoticeBufferSeconds == 2.0)
        #expect(c.overlaySecondsPerWord == 0.35)
        #expect(c.overlayMaxDisplaySeconds == 8)
        #expect(c.transcriptionModel == "gpt-4o-transcribe")
        #expect(c.vadSilenceDurationMs == 1000)
        #expect(c.turnDebounceSeconds == 0.4)
        #expect(c.maxBufferedAudioSeconds == 60)
    }

    @Test func overlayAppearanceConstants() {
        #expect(Config.overlayCaptionFontSizeDefault == 18)
        #expect(Config.overlayCaptionFontSizeRange == 12...32)
        #expect(Config.overlayCaptionOpacityDefault == 0.78)
        #expect(Config.overlayCaptionOpacityRange == 0.40...1.0)
        #expect(Config.overlayBoxFontSizeDefault == 14)
        #expect(Config.overlayBoxOpacityDefault == 1.0)
        // The two surfaces default opposite ways: caption off, box on.
        #expect(Config.overlayCaptionEnabledDefault == false)
        #expect(Config.overlayBoxEnabledDefault == true)
    }

    /// Invariants the rest of the code relies on, independent of the exact literals above:
    /// each default must sit inside its range, and each range must be non-empty.
    @Test func overlayAppearanceConstantsAreCoherent() {
        for (range, def) in [(Config.overlayCaptionFontSizeRange, Config.overlayCaptionFontSizeDefault),
                             (Config.overlayCaptionOpacityRange, Config.overlayCaptionOpacityDefault),
                             (Config.overlayBoxFontSizeRange, Config.overlayBoxFontSizeDefault),
                             (Config.overlayBoxOpacityRange, Config.overlayBoxOpacityDefault)] {
            #expect(range.contains(def))
            #expect(range.lowerBound < range.upperBound)
        }
    }

    /// The overlay timing knobs must form a usable model: a positive buffer and per-word rate, a cap
    /// above the buffer (so even a one-word line fits under it), and a non-negative inter-line gap.
    @Test func overlayTimingConstantsAreCoherent() {
        let c = Config.default
        #expect(c.overlayNoticeBufferSeconds > 0)
        #expect(c.overlaySecondsPerWord > 0)
        #expect(c.overlayMaxDisplaySeconds > c.overlayNoticeBufferSeconds)
        #expect(Config.overlayLineGapSeconds >= 0)
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
