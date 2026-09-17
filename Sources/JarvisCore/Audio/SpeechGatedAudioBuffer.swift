import Foundation

/// Holds a short pre-roll while idle, so idle silence is never uploaded but onset context is kept.
public struct SpeechGatedAudioBuffer: Sendable {
    private let maximumPreRollDuration: TimeInterval
    private var preRoll: [PCMBuffer.Chunk] = []
    private var preRollDuration: TimeInterval = 0
    private var speechIsActive = false

    public init(maximumPreRollDuration: TimeInterval = 0.3) {
        precondition(maximumPreRollDuration >= 0 && maximumPreRollDuration.isFinite)
        self.maximumPreRollDuration = maximumPreRollDuration
    }

    /// Always keeps the newest idle chunk, which may hold the onset, so the pre-roll can exceed its
    /// bound by one chunk.
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

    public mutating func speechStarted() -> [PCMBuffer.Chunk] {
        guard !speechIsActive else { return [] }
        speechIsActive = true
        let buffered = preRoll
        preRoll.removeAll(keepingCapacity: true)
        preRollDuration = 0
        return buffered
    }

    public mutating func speechEnded() {
        speechIsActive = false
    }

    public mutating func clear() {
        preRoll.removeAll(keepingCapacity: false)
        preRollDuration = 0
        speechIsActive = false
    }
}
