import Foundation
import JarvisCore

/// Delivery closures are fixed at construction so a real-time producer can hold them as `let`s read
/// from its audio thread.
protocol AudioSource: AnyObject, Sendable {
    /// Nil on success, else a human-readable reason.
    func start() -> String?
    func stop()
    var onUnavailable: (@Sendable (String) -> Void)? { get set }
    /// True while the source owns a bounded recovery incident, false once it recovers.
    var onRecoveryStateChange: (@Sendable (Bool) -> Void)? { get set }
}

/// For each chunk the source calls the captured closure before the clean one, with the same
/// sequence number, as the continuity witness expects.
struct AudioDelivery: Sendable {
    let onMicCaptured: @Sendable (UInt64, Int, TimeInterval) -> Void
    let onSystemCaptured: @Sendable (UInt64, Int, TimeInterval) -> Void
    let onMicClean: @Sendable (Data, UInt64, TimeInterval) -> Void
    let onSystem: @Sendable (Data, UInt64, TimeInterval) -> Void
    let onMicSpeechEvent: @Sendable (LocalSpeechEvent, UInt64) -> Void
    let onSystemSpeechEvent: @Sendable (LocalSpeechEvent, UInt64) -> Void
}

/// `TimeInterval?`: local turn-detection silence duration, nil when the model detects turns.
typealias MakeAudioSource =
    (TranscriptionAudioFormat, TimeInterval?, AudioDelivery) -> any AudioSource
