import Foundation

/// All tunables from specification.md §5. Plain values; tune freely.
public struct Config: Sendable {
    public var silenceTimeoutSeconds: TimeInterval
    public var cooldownSeconds: TimeInterval
    public var maxInterjectionsPerMinute: Int
    public var transcriptWindowSeconds: TimeInterval
    public var sentenceDisplaySeconds: TimeInterval
    public var maxSentences: Int
    public var brainModel: String
    public var transcriptionModel: String

    public init(
        silenceTimeoutSeconds: TimeInterval = 8,
        cooldownSeconds: TimeInterval = 12,
        maxInterjectionsPerMinute: Int = 4,
        transcriptWindowSeconds: TimeInterval = 90,
        sentenceDisplaySeconds: TimeInterval = 5,
        maxSentences: Int = 3,
        brainModel: String = "gpt-5.5",
        transcriptionModel: String = "gpt-realtime-2"
    ) {
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxInterjectionsPerMinute = maxInterjectionsPerMinute
        self.transcriptWindowSeconds = transcriptWindowSeconds
        self.sentenceDisplaySeconds = sentenceDisplaySeconds
        self.maxSentences = maxSentences
        self.brainModel = brainModel
        self.transcriptionModel = transcriptionModel
    }

    public static let `default` = Config()
}
