import Foundation

/// PCM contract between capture and one live transcription adapter. The rate is a provider
/// requirement — OpenAI Realtime takes 24 kHz, Gemini Live takes 16 kHz — not a quality knob:
/// speech carries nothing above 8 kHz that a recognizer uses, so 16 kHz is already sufficient.
public struct TranscriptionAudioFormat: Equatable, Sendable {
    /// OpenAI Realtime's required input rate; also what Apple Speech is fed today.
    public static let pcm16Mono24k = TranscriptionAudioFormat(
        sampleRate: 24_000,
        channelCount: 1,
        bytesPerSample: MemoryLayout<Int16>.size)

    /// Gemini Live's required input rate (`audio/pcm;rate=16000`).
    public static let pcm16Mono16k = TranscriptionAudioFormat(
        sampleRate: 16_000,
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
