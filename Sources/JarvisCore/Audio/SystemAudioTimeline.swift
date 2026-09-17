import Foundation

/// Core Audio can return a short or empty system tap for a mic callback. Padding, never truncating,
/// keeps the audio clock moving so server VAD sees trailing silence and finalizes the interviewer.
public enum SystemAudioTimeline {
    public static func preservingSamples(_ samples: [Int16],
                                         minimumFrameCount: Int) -> [Int16] {
        precondition(minimumFrameCount >= 0, "Frame count cannot be negative")
        guard samples.count < minimumFrameCount else { return samples }
        return samples + repeatElement(0, count: minimumFrameCount - samples.count)
    }
}
