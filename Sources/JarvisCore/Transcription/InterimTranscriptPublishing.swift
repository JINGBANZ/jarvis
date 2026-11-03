import Foundation

/// A transcription session that can show the utterance it is still recognizing. Display-only: the
/// text is speculative, so it must never reach the transcript, Activity, or a model request.
public protocol InterimTranscriptPublishing: AnyObject {
    /// Nil once the utterance finalizes.
    var onInterimTranscript: (@Sendable (String?) -> Void)? { get set }
}
