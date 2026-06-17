import Foundation

/// All tunables from specification.md §5. Plain values; tune freely.
public struct Config: Sendable {
    /// Base quiet interval before the first proactive "are you stuck?" silence check. Subsequent
    /// checks back off exponentially (see `silenceMaxIntervalSeconds` and `SilenceBackoff`); any
    /// speech resets to this base.
    public var silenceTimeoutSeconds: TimeInterval
    /// Upper bound on the silence-check interval as it backs off, so a long silence still gets an
    /// occasional gentle check rather than going dark forever.
    public var silenceMaxIntervalSeconds: TimeInterval
    public var transcriptWindowSeconds: TimeInterval
    public var sentenceDisplaySeconds: TimeInterval
    public var maxSentences: Int
    /// Brain model. `gpt-5.5` confirmed against OpenAI docs (snapshot `gpt-5.5-2026-04-23`);
    /// vision + function calling via the Responses API.
    public var brainModel: String
    /// Reasoning effort for the Responses API. Valid for gpt-5.5: none | low | medium (default) |
    /// high | xhigh. `low` keeps the turn fast (sub-2s target) while still allowing tool calls.
    public var reasoningEffort: String
    /// Realtime transcription model. `gpt-4o-transcribe` — supports `server_vad` turn detection,
    /// so the Realtime server auto-commits the audio buffer at each speech boundary and emits
    /// `…transcription.completed` (this is what makes the coach loop fire). `gpt-realtime-whisper`
    /// is lower-latency but has NO server VAD — it would require manual `input_audio_buffer.commit`.
    public var transcriptionModel: String
    /// Server-VAD silence window: how long a pause must last before the server ends the turn.
    /// Raised above the ~500 ms server default so a mid-thought pause doesn't split a sentence.
    public var vadSilenceDurationMs: Int
    /// Client-side coalescing window: rapid `…transcription.completed` fragments arriving within this
    /// window are merged into one coaching trigger, so even residual VAD fragmentation doesn't drive
    /// multiple brain calls for one spoken sentence.
    public var turnDebounceSeconds: TimeInterval
    /// How many seconds of mic audio to buffer while the realtime socket is down, flushed into the
    /// new session on reconnect so a mid-sentence drop isn't lost. Capped so a long outage can't grow
    /// memory without bound (the oldest audio is evicted past the cap).
    public var maxBufferedAudioSeconds: TimeInterval

    public init(
        silenceTimeoutSeconds: TimeInterval = 30,
        silenceMaxIntervalSeconds: TimeInterval = 240,
        transcriptWindowSeconds: TimeInterval = 90,
        sentenceDisplaySeconds: TimeInterval = 5,
        maxSentences: Int = 3,
        brainModel: String = "gpt-5.5",
        reasoningEffort: String = "low",
        transcriptionModel: String = "gpt-4o-transcribe",
        vadSilenceDurationMs: Int = 1000,
        turnDebounceSeconds: TimeInterval = 0.4,
        maxBufferedAudioSeconds: TimeInterval = 60
    ) {
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.silenceMaxIntervalSeconds = silenceMaxIntervalSeconds
        self.transcriptWindowSeconds = transcriptWindowSeconds
        self.sentenceDisplaySeconds = sentenceDisplaySeconds
        self.maxSentences = maxSentences
        self.brainModel = brainModel
        self.reasoningEffort = reasoningEffort
        self.transcriptionModel = transcriptionModel
        self.vadSilenceDurationMs = vadSilenceDurationMs
        self.turnDebounceSeconds = turnDebounceSeconds
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
    }

    public static let `default` = Config()
}
