import Foundation

/// Keeps a bounded PCM pre-roll while speech is idle, then passes complete chunks through from a
/// confirmed onset until the matching endpoint. This prevents client-commit transcription from
/// uploading indefinite idle silence while preserving onset context and short pauses.
public struct SpeechGatedAudioBuffer: Sendable {
    private let maximumPreRollDuration: TimeInterval
    private var preRoll: [PCMBuffer.Chunk] = []
    private var preRollDuration: TimeInterval = 0
    private var speechIsActive = false

    public init(maximumPreRollDuration: TimeInterval = 0.3) {
        precondition(maximumPreRollDuration >= 0 && maximumPreRollDuration.isFinite)
        self.maximumPreRollDuration = maximumPreRollDuration
    }

    /// Accept one ordered audio chunk. Idle chunks stay local; active chunks pass through at once.
    /// The newest whole chunk is always retained because it may contain the onset that confirms
    /// speech, so the duration bound can be exceeded by at most one capture chunk.
    public mutating func append(_ chunk: PCMBuffer.Chunk) -> [PCMBuffer.Chunk] {
        guard !chunk.data.isEmpty else { return [] }
        guard !speechIsActive else { return [chunk] }

        preRoll.append(chunk)
        preRollDuration += chunk.duration
        while preRoll.count > 1,
              preRollDuration > maximumPreRollDuration + 0.000_000_001 {
            preRollDuration -= preRoll.removeFirst().duration
        }
        return []
    }

    /// Open the gate and release retained onset context in FIFO order.
    public mutating func speechStarted() -> [PCMBuffer.Chunk] {
        guard !speechIsActive else { return [] }
        speechIsActive = true
        let buffered = preRoll
        preRoll.removeAll(keepingCapacity: true)
        preRollDuration = 0
        return buffered
    }

    /// Close the gate after the endpoint detector has delivered its configured trailing silence.
    public mutating func speechEnded() {
        speechIsActive = false
    }

    public mutating func clear() {
        preRoll.removeAll(keepingCapacity: false)
        preRollDuration = 0
        speechIsActive = false
    }
}
