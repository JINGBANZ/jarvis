import Foundation

/// All harness tunables in one place. Plain values; tune freely. (Rationale: wiki/architecture.md.)
public struct Config: Sendable {
    /// Base quiet interval before the first proactive "are you stuck?" silence check. Subsequent
    /// checks back off exponentially (see `silenceMaxIntervalSeconds` and `SilenceBackoff`); any
    /// speech resets to this base.
    public var silenceTimeoutSeconds: TimeInterval
    /// Upper bound on the silence-check interval as it backs off, so a long silence still gets an
    /// occasional gentle check rather than going dark forever.
    public var silenceMaxIntervalSeconds: TimeInterval
    public var transcriptWindowSeconds: TimeInterval
    /// How long each overlay line is shown before advancing to the next. The brain returns the lines
    /// pre-split (the `speak` tool's `lines` array); there is no client-side cap on how many.
    public var lineDisplaySeconds: TimeInterval
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
        silenceTimeoutSeconds: TimeInterval = 120,
        silenceMaxIntervalSeconds: TimeInterval = 960,
        transcriptWindowSeconds: TimeInterval = 90,
        lineDisplaySeconds: TimeInterval = 15,
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
        self.lineDisplaySeconds = lineDisplaySeconds
        self.brainModel = brainModel
        self.reasoningEffort = reasoningEffort
        self.transcriptionModel = transcriptionModel
        self.vadSilenceDurationMs = vadSilenceDurationMs
        self.turnDebounceSeconds = turnDebounceSeconds
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
    }

    // Overlay appearance: defaults + allowed ranges. The persisted values live in UserDefaults via
    // OverlayAppearance; these are the single source of the defaults and the clamp bounds.
    public static let overlayFontSizeRange: ClosedRange<Double> = 12...32
    public static let overlayFontSizeDefault: Double = 18
    public static let overlayOpacityRange: ClosedRange<Double> = 0.40...1.0
    public static let overlayOpacityDefault: Double = 0.78

    public static let `default` = Config()
}
