import Foundation

/// Harness tunables the user never sees. User-facing settings belong in `Defaults`.
public struct Config: Sendable {
    /// Short on purpose: a stuck candidate's muttered fragments keep restarting it.
    /// See wiki/architecture.md#the-turn.
    public var silenceTimeoutSeconds: TimeInterval
    public var silenceMaxIntervalSeconds: TimeInterval
    public var silenceIdleCutoffSeconds: TimeInterval
    /// Estimated tokens. Inside the usual 5-20k conversational band, so compaction stays rare and
    /// per-request input stays cheap.
    public var historyCompactionTokenThreshold: Int
    public var overlayNoticeBufferSeconds: TimeInterval
    public var overlaySecondsPerWord: TimeInterval
    public var overlayMaxDisplaySeconds: TimeInterval
    /// Server VAD only (GPT-4o Transcribe). Above OpenAI's ~500 ms default so a mid-thought pause
    /// doesn't split a sentence.
    public var vadSilenceDurationMs: Int
    /// Local Silero endpointer only. Kept separate from `vadSilenceDurationMs` because the two tune
    /// different detectors. 800 ms matches Pipecat; a late hint beats cutting the speaker off.
    public var localEndpointSilenceDurationMs: Int
    public var audioNoiseReduction: NoiseReductionMode
    public var transcriptBatchingWindowSeconds: TimeInterval
    public var maxBufferedAudioSeconds: TimeInterval
    public var realtimeReadyTimeoutSeconds: TimeInterval
    public var realtimePingIntervalSeconds: TimeInterval
    public var realtimePongTimeoutSeconds: TimeInterval

    public init(
        silenceTimeoutSeconds: TimeInterval = 45,
        silenceMaxIntervalSeconds: TimeInterval = 960,
        silenceIdleCutoffSeconds: TimeInterval = 1_800,
        historyCompactionTokenThreshold: Int = 10_000,
        overlayNoticeBufferSeconds: TimeInterval = 2.0,
        overlaySecondsPerWord: TimeInterval = 0.35,
        overlayMaxDisplaySeconds: TimeInterval = 8,
        vadSilenceDurationMs: Int = 1000,
        localEndpointSilenceDurationMs: Int = 800,
        audioNoiseReduction: NoiseReductionMode = .auto,
        transcriptBatchingWindowSeconds: TimeInterval = 0.4,
        maxBufferedAudioSeconds: TimeInterval = 60,
        realtimeReadyTimeoutSeconds: TimeInterval = 10,
        realtimePingIntervalSeconds: TimeInterval = 20,
        realtimePongTimeoutSeconds: TimeInterval = 10
    ) {
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.silenceMaxIntervalSeconds = silenceMaxIntervalSeconds
        self.silenceIdleCutoffSeconds = silenceIdleCutoffSeconds
        self.historyCompactionTokenThreshold = historyCompactionTokenThreshold
        self.overlayNoticeBufferSeconds = overlayNoticeBufferSeconds
        self.overlaySecondsPerWord = overlaySecondsPerWord
        self.overlayMaxDisplaySeconds = overlayMaxDisplaySeconds
        self.vadSilenceDurationMs = vadSilenceDurationMs
        self.localEndpointSilenceDurationMs = localEndpointSilenceDurationMs
        self.audioNoiseReduction = audioNoiseReduction
        self.transcriptBatchingWindowSeconds = transcriptBatchingWindowSeconds
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
        self.realtimeReadyTimeoutSeconds = realtimeReadyTimeoutSeconds
        self.realtimePingIntervalSeconds = realtimePingIntervalSeconds
        self.realtimePongTimeoutSeconds = realtimePongTimeoutSeconds
    }

    /// Static because the overlay panel reads it during playback without a `Config` instance.
    public static let overlayLineGapSeconds: TimeInterval = 0.2

    public static let `default` = Config()
}
