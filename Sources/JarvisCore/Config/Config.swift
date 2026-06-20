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
    /// Fixed time added to every overlay line before its reading time. Unlike a movie viewer (eyes on
    /// the screen, audio reinforcing the text), our user is mid-conversation and only *glances* at the
    /// overlay — so the dominant cost is noticing the tip and redirecting their gaze, which is constant
    /// regardless of line length. This buffer models that; it also sets the natural floor (buffer + one
    /// word). See `OverlayTiming` and wiki/overlay-timing.md.
    public var overlayNoticeBufferSeconds: TimeInterval
    /// Reading time per word, added on top of the notice buffer. Can be near normal reading speed —
    /// the glance latency is already covered by the buffer, so this term need only cover actual reading.
    public var overlaySecondsPerWord: TimeInterval
    /// Ceiling on a line's display time. Tighter than movie-caption caps (~6–7s): a coaching tip goes
    /// stale fast, and an over-long display also delays the next queued (fresher) tip.
    public var overlayMaxDisplaySeconds: TimeInterval
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
        overlayNoticeBufferSeconds: TimeInterval = 2.0,
        overlaySecondsPerWord: TimeInterval = 0.35,
        overlayMaxDisplaySeconds: TimeInterval = 8,
        transcriptionModel: String = "gpt-4o-transcribe",
        vadSilenceDurationMs: Int = 1000,
        turnDebounceSeconds: TimeInterval = 0.4,
        maxBufferedAudioSeconds: TimeInterval = 60
    ) {
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.silenceMaxIntervalSeconds = silenceMaxIntervalSeconds
        self.transcriptWindowSeconds = transcriptWindowSeconds
        self.overlayNoticeBufferSeconds = overlayNoticeBufferSeconds
        self.overlaySecondsPerWord = overlaySecondsPerWord
        self.overlayMaxDisplaySeconds = overlayMaxDisplaySeconds
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

    /// Brief blank shown between consecutive overlay lines (and before the next queued tip). Borrowed
    /// from the captioning minimum-gap rule: without it, back-to-back lines read as one block and the
    /// eye doesn't re-trigger — worse for a glancing user than a watching one. See wiki/overlay-timing.md.
    ///
    /// Static (unlike the instance reading-time knobs above) because it's consumed inside the
    /// `JarvisOverlay` panel during playback, which is never handed a `Config` instance — same reason
    /// the appearance defaults above are statics. The per-line *durations* differ: they're computed in
    /// Core from a `Config` instance and passed into the overlay, so they stay instance properties.
    public static let overlayLineGapSeconds: TimeInterval = 0.2

    public static let `default` = Config()
}
