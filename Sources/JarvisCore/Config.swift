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
    /// Reasoning effort for the Responses API (gpt-5 family): minimal | low | medium | high.
    /// `low` keeps the turn fast (sub-2s target) while still allowing tool calls.
    public var reasoningEffort: String
    /// Realtime transcription model. `gpt-realtime-whisper` — OpenAI's streaming low-latency STT
    /// model (transcript deltas from live audio). Paired with `server_vad` turn detection so the
    /// audio buffer auto-commits per utterance. `gpt-4o-transcribe` is an alternative.
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
        transcriptionModel: String = "gpt-realtime-whisper"
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
