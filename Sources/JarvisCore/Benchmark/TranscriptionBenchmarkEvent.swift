import Foundation

/// One benchmark-only observation from a real transcription provider lifecycle.
///
/// Events may contain transcript text but never audio. They exist only while an explicit benchmark
/// run supplies `TranscriptionBenchmarkInstrumentation`; normal coaching constructs and records none.
public struct TranscriptionBenchmarkEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ready
        case serverEndpoint = "server-endpoint"
        case clientCommit = "client-commit"
        case providerFinal = "provider-final"
        case finalized
        case reconnectPrepared = "reconnect-prepared"
        case bufferEviction = "buffer-eviction"
    }

    public let kind: Kind
    public let provider: String
    public let model: String?
    public let localeIdentifier: String?
    public let speaker: String
    public let generation: Int
    public let itemID: String?
    public let text: String?
    public let spokenAt: TimeInterval?
    public let spokenEndAt: TimeInterval?
    public let audioBoundaryAt: TimeInterval?
    public let observedAt: TimeInterval
    public let recoveredFromDeltas: Bool
    public let transcriptUnavailable: Bool
    public let reconnectAttempt: Int?
    public let replayedChunks: Int?
    public let evictedChunks: Int?
    public let oldestReplaySequence: UInt64?

    public init(
        kind: Kind,
        provider: String,
        model: String? = nil,
        localeIdentifier: String? = nil,
        speaker: String,
        generation: Int,
        itemID: String? = nil,
        text: String? = nil,
        spokenAt: TimeInterval? = nil,
        spokenEndAt: TimeInterval? = nil,
        audioBoundaryAt: TimeInterval? = nil,
        observedAt: TimeInterval,
        recoveredFromDeltas: Bool = false,
        transcriptUnavailable: Bool = false,
        reconnectAttempt: Int? = nil,
        replayedChunks: Int? = nil,
        evictedChunks: Int? = nil,
        oldestReplaySequence: UInt64? = nil
    ) {
        self.kind = kind
        self.provider = provider
        self.model = model
        self.localeIdentifier = localeIdentifier
        self.speaker = speaker
        self.generation = generation
        self.itemID = itemID
        self.text = text
        self.spokenAt = spokenAt
        self.spokenEndAt = spokenEndAt
        self.audioBoundaryAt = audioBoundaryAt
        self.observedAt = observedAt
        self.recoveredFromDeltas = recoveredFromDeltas
        self.transcriptUnavailable = transcriptUnavailable
        self.reconnectAttempt = reconnectAttempt
        self.replayedChunks = replayedChunks
        self.evictedChunks = evictedChunks
        self.oldestReplaySequence = oldestReplaySequence
    }
}
