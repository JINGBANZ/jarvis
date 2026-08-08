import Foundation

/// Provider-neutral live transcription endpoint for one speaker stream. OS- and transport-specific
/// adapters own their setup and recovery; the app owns the two sessions and feeds them ordered mono
/// PCM16 captured in `TranscriptionAudioFormat.pcm16Mono`.
public protocol TranscriptionSession: AnyObject, Sendable {
    var onTurnEnd: (@Sendable () -> Void)? { get set }
    var onSilence: (@Sendable (TimeInterval) -> Void)? { get set }
    var onSpeechActivityChanged: (@Sendable (Bool) -> Void)? { get set }
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)? { get set }
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)? { get set }
    /// Content-free capture progress/stall edges derived from this endpoint's continuity witness.
    /// They let Core combine positive sample-count progress with provider readiness without exposing
    /// amplitude or PCM. See `CaptureReadinessMonitor`.
    var onCaptureContinuity: (@Sendable (CaptureReadinessMonitor.Signal) -> Void)? { get set }

    func connect()
    func stop()
    func recordCapturedAudio(
        sequenceNumber: UInt64,
        sampleCount: Int,
        capturedAt: TimeInterval
    )
    func sendAudio(
        _ pcm: Data,
        sequenceNumber: UInt64,
        capturedAt: TimeInterval
    )
    func recordLocalSpeechEvent(
        _ event: LocalSpeechEvent,
        throughSequenceNumber: UInt64
    )
}

public extension TranscriptionSession {
    /// Providers with their own turn detector ignore capture-side speech edges.
    func recordLocalSpeechEvent(
        _ event: LocalSpeechEvent,
        throughSequenceNumber: UInt64
    ) {}
}
