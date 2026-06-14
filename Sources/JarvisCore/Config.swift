import Foundation

/// All tunables from specification.md §5. Plain values; tune freely.
public struct Config: Sendable {
    public var silenceTimeoutSeconds: TimeInterval
    public var cooldownSeconds: TimeInterval
    public var maxInterjectionsPerMinute: Int
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

    public init(
        silenceTimeoutSeconds: TimeInterval = 8,
        cooldownSeconds: TimeInterval = 12,
        maxInterjectionsPerMinute: Int = 4,
        transcriptWindowSeconds: TimeInterval = 90,
        sentenceDisplaySeconds: TimeInterval = 5,
        maxSentences: Int = 3,
        brainModel: String = "gpt-5.5",
        reasoningEffort: String = "low",
        transcriptionModel: String = "gpt-4o-transcribe"
    ) {
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxInterjectionsPerMinute = maxInterjectionsPerMinute
        self.transcriptWindowSeconds = transcriptWindowSeconds
        self.sentenceDisplaySeconds = sentenceDisplaySeconds
        self.maxSentences = maxSentences
        self.brainModel = brainModel
        self.reasoningEffort = reasoningEffort
        self.transcriptionModel = transcriptionModel
    }

    public static let `default` = Config()
}
