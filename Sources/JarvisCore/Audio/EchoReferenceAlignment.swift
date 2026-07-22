import Foundation

/// Builds the frame-aligned far-end copy AEC needs without altering the system-audio samples that
/// are sent to transcription. The capture and reference framers must advance by the same count, but
/// that transport requirement must never truncate an interviewer's audio.
public enum EchoReferenceAlignment {
    public static func aligned(_ reference: [Int16], toFrameCount frameCount: Int) -> [Int16] {
        precondition(frameCount >= 0, "Frame count cannot be negative")
        if reference.count == frameCount { return reference }
        if reference.count > frameCount { return Array(reference.prefix(frameCount)) }
        return reference + repeatElement(0, count: frameCount - reference.count)
    }
}
