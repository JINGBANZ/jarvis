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
        #expect(c.vadSilenceDurationMs == 1000)
        #expect(c.transcriptBatchingWindowSeconds == 0.4)
        #expect(c.maxBufferedAudioSeconds == 60)
        #expect(c.realtimeReadyTimeoutSeconds == 10)
        #expect(c.realtimePingIntervalSeconds == 20)
        #expect(c.realtimePongTimeoutSeconds == 10)
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

    @Test func realtimeHealthConstantsAreCoherent() {
        let c = Config.default
        #expect(c.realtimeReadyTimeoutSeconds > 0)
        #expect(c.realtimePingIntervalSeconds > 0)
        #expect(c.realtimePongTimeoutSeconds > 0)
    }

    @Test func envSecretStoreReadsKey() {
        let store = EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-test"])
        #expect(store.apiKey() == "sk-test")
    }

    @Test func envSecretStoreMissingKey() {
        let store = EnvSecretStore(environment: [:])
        #expect(store.apiKey() == nil)
    }

    @Test func chainedSecretStoreUsesFirstAvailableKey() {
        let fallback = ChainedSecretStore([
            EnvSecretStore(environment: [:]),
            EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-fallback"]),
        ])
        #expect(fallback.apiKey() == "sk-fallback")

        let primary = ChainedSecretStore([
            EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-primary"]),
            EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-fallback"]),
        ])
        #expect(primary.apiKey() == "sk-primary")
    }
}
