import Foundation

/// Preserves every captured far-end sample while keeping the transcription stream's audio clock
/// moving through tap silence. Core Audio may return a short or empty system tap for a mic callback;
/// padding that missing tail lets server VAD observe trailing silence and finalize the interviewer.
public enum SystemAudioTimeline {
    public static func preservingSamples(_ samples: [Int16],
                                         minimumFrameCount: Int) -> [Int16] {
        precondition(minimumFrameCount >= 0, "Frame count cannot be negative")
        guard samples.count < minimumFrameCount else { return samples }
        return samples + repeatElement(0, count: minimumFrameCount - samples.count)
    }
}
