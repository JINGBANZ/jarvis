import Foundation

/// Provider-neutral live transcription endpoint for one speaker stream. OS- and transport-specific
/// adapters own their setup and recovery; the app owns the two sessions and feeds them ordered mono
/// PCM16 captured in `TranscriptionAudioFormat.pcm16Mono`.
public protocol TranscriptionSession: AnyObject, Sendable {
    /// Exclusive transcript insertion boundary represented by this finalized turn.
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)? { get set }
    var onSilence: (@Sendable (TimeInterval) -> Void)? { get set }
    /// `true` while this provider owns active speech, finalization, or recovery work that can still
    /// produce an earlier transcript line; `false` only when its current chronology is settled.
    var onTranscriptionWorkChanged: (@Sendable (Bool) -> Void)? { get set }
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)? { get set }
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)? { get set }
    /// Content-free capture progress/stall edges derived from this endpoint's continuity witness.
    /// They let Core combine positive sample-count progress with provider readiness without exposing
    /// amplitude or PCM. See `CaptureReadinessMonitor`.
    var onCaptureHeartbeat: (@Sendable (CaptureHeartbeat) -> Void)? { get set }
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
