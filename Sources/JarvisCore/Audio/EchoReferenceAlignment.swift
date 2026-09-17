import Foundation

/// Aligns AEC's far-end copy only. The system audio sent to transcription must never be truncated.
public enum EchoReferenceAlignment {
    public static func aligned(_ reference: [Int16], toFrameCount frameCount: Int) -> [Int16] {
        precondition(frameCount >= 0, "Frame count cannot be negative")
        if reference.count == frameCount { return reference }
        if reference.count > frameCount { return Array(reference.prefix(frameCount)) }
        return reference + repeatElement(0, count: frameCount - reference.count)
    }
}
