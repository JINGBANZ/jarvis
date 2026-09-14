import Foundation
import JarvisCore

/// What the session composition needs from whatever produces the two speech streams.
///
/// The delivery closures are handed to the source at construction and never changed afterwards,
/// which is what lets a real-time producer keep them as `let`s read from its audio thread.
protocol AudioSource: AnyObject, Sendable {
    /// Build and start producing frames. Nil on success, else a human-readable reason the caller
    /// surfaces through `ErrorReporter`.
    func start() -> String?
    func stop()
    /// Fired if the source becomes unusable mid-session. Carries a human-readable reason.
    var onUnavailable: (@Sendable (String) -> Void)? { get set }
    /// True while the source owns a bounded recovery incident, false once it recovers.
    var onRecoveryStateChange: (@Sendable (Bool) -> Void)? { get set }
}

/// Where a source delivers each stream: microphone frames to the "me" endpoint and system frames to
/// the "them" endpoint. For each chunk the source calls the captured closure before the clean one,
/// with the same sequence number, which is what the transcriber's continuity witness expects.
struct AudioDelivery: Sendable {
    let onMicCaptured: @Sendable (UInt64, Int, TimeInterval) -> Void
    let onSystemCaptured: @Sendable (UInt64, Int, TimeInterval) -> Void
    let onMicClean: @Sendable (Data, UInt64, TimeInterval) -> Void
    let onSystem: @Sendable (Data, UInt64, TimeInterval) -> Void
    let onMicSpeechEvent: @Sendable (LocalSpeechEvent, UInt64) -> Void
    let onSystemSpeechEvent: @Sendable (LocalSpeechEvent, UInt64) -> Void
}

/// Builds the session's source from the provider's wire format, the local turn-detection silence
/// duration (nil when the transcription model detects turns itself), and the delivery targets.
typealias MakeAudioSource =
    (TranscriptionAudioFormat, TimeInterval?, AudioDelivery) -> any AudioSource
