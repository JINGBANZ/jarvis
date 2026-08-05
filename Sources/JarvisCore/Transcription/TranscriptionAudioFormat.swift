import Foundation

/// Provider-neutral PCM contract shared by capture and every live transcription adapter.
public struct TranscriptionAudioFormat: Equatable, Sendable {
    public static let pcm16Mono = TranscriptionAudioFormat(
        sampleRate: 24_000,
        channelCount: 1,
        bytesPerSample: MemoryLayout<Int16>.size)

    public let sampleRate: Int
    public let channelCount: Int
    public let bytesPerSample: Int

    public init(sampleRate: Int, channelCount: Int, bytesPerSample: Int) {
        precondition(sampleRate > 0)
        precondition(channelCount > 0)
        precondition(bytesPerSample > 0)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
    }

    public var bytesPerSecond: Int {
        sampleRate * channelCount * bytesPerSample
    }

    public func duration(forByteCount byteCount: Int) -> TimeInterval {
        TimeInterval(max(0, byteCount)) / TimeInterval(bytesPerSecond)
    }

    public func byteCount(forDuration duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int(duration * TimeInterval(bytesPerSecond))
    }
}
