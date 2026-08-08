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
    /// Stop the silence checks entirely once the user has been continuously quiet this long — they
    /// have stepped away, and every probe into the empty room still bills a full-history brain
    /// request (often plus a screenshot). Speech re-arms the checks from the base interval.
    public var silenceIdleCutoffSeconds: TimeInterval
    /// When the client-managed session memory (`CoachHistory`) grows past this many estimated tokens,
    /// the driver condenses its oldest span into a short summary (see `CoachDriver.compactIfNeeded`).
    /// Sized to industry practice for conversational loads (~5–20k): big enough that compaction is
    /// rare (a few times an hour), small enough that per-request input stays cheap. The estimator is
    /// conservative for non-ASCII scripts so this boundary is useful in multilingual sessions.
    public var historyCompactionTokenThreshold: Int
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
    /// Server-VAD silence window: how long a pause must last before the server ends the turn.
    /// Raised above the ~500 ms server default so a mid-thought pause doesn't split a sentence.
    public var vadSilenceDurationMs: Int
    /// Input noise-reduction policy applied *before* VAD, to stop non-speech blips from firing the VAD
    /// and producing phantom transcripts. `.auto` (default) picks `near_field` vs `far_field` from the
    /// active mic's Core Audio transport type each session (see `NoiseReduction` / `InputDeviceProximity`);
    /// or pin `.nearField` / `.farField`, or `.off` to disable.
    public var audioNoiseReduction: NoiseReductionMode
    /// Client-side coalescing window: rapid `…transcription.completed` fragments arriving within this
    /// window are merged into one coaching trigger, so even residual VAD fragmentation doesn't drive
    /// multiple brain calls for one spoken sentence.
    public var turnDebounceSeconds: TimeInterval
    /// How many seconds of mic audio to buffer while the realtime socket is down, flushed into the
    /// new session on reconnect so a mid-sentence drop isn't lost. Capped so a long outage can't grow
    /// memory without bound (the oldest audio is evicted past the cap).
    public var maxBufferedAudioSeconds: TimeInterval
    /// Maximum time for a new Realtime socket to receive the server's session-ready event. Audio is
    /// buffered during this window; a silent handshake/configuration hang is then reconnected.
    public var realtimeReadyTimeoutSeconds: TimeInterval
    /// Interval between WebSocket ping/pong health probes while a transcription session is ready.
    public var realtimePingIntervalSeconds: TimeInterval
    /// Maximum time to receive a pong before declaring the apparently-open socket unhealthy.
    public var realtimePongTimeoutSeconds: TimeInterval

    public init(
        silenceTimeoutSeconds: TimeInterval = 120,
        silenceMaxIntervalSeconds: TimeInterval = 960,
        silenceIdleCutoffSeconds: TimeInterval = 1_800,
        historyCompactionTokenThreshold: Int = 10_000,
        overlayNoticeBufferSeconds: TimeInterval = 2.0,
        overlaySecondsPerWord: TimeInterval = 0.35,
        overlayMaxDisplaySeconds: TimeInterval = 8,
        vadSilenceDurationMs: Int = 1000,
        audioNoiseReduction: NoiseReductionMode = .auto,
        turnDebounceSeconds: TimeInterval = 0.4,
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
        self.audioNoiseReduction = audioNoiseReduction
        self.turnDebounceSeconds = turnDebounceSeconds
        self.maxBufferedAudioSeconds = maxBufferedAudioSeconds
        self.realtimeReadyTimeoutSeconds = realtimeReadyTimeoutSeconds
        self.realtimePingIntervalSeconds = realtimePingIntervalSeconds
        self.realtimePongTimeoutSeconds = realtimePongTimeoutSeconds
    }

    // Overlay appearance: defaults + allowed ranges. The persisted values live in UserDefaults via
    // OverlayAppearance; these are the single source of the defaults and the clamp bounds.
    //
    // The overlay has two surfaces, each independently switchable: the Overlay Caption (the transient
    // on-screen tip) and the Overlay Box (the persistent history of responses). The caption is off by
    // default and the box on, so a first run shows the durable history rather than a flashing caption.
    public static let overlayCaptionFontSizeRange: ClosedRange<Double> = 12...32
    public static let overlayCaptionFontSizeDefault: Double = 18
    public static let overlayCaptionOpacityRange: ClosedRange<Double> = 0.40...1.0
    public static let overlayCaptionOpacityDefault: Double = 0.78
    public static let overlayCaptionEnabledDefault: Bool = false
    // The persistent overlay box: its background-fill opacity. Defaults fully opaque (the box is a
    // readout meant to stay legible); the lower bound matches the caption so it can be dimmed too.
    public static let overlayBoxOpacityRange: ClosedRange<Double> = 0.40...1.0
    public static let overlayBoxOpacityDefault: Double = 1.0
    public static let overlayBoxFontSizeRange: ClosedRange<Double> = 12...32
    public static let overlayBoxFontSizeDefault: Double = 14
    public static let overlayBoxEnabledDefault: Bool = true

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
