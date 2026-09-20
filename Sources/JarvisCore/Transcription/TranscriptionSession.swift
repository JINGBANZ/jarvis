import Foundation

/// Fed ordered mono PCM16 at the rate `TranscriptionProvider.audioFormat` selects.
public protocol TranscriptionSession: AnyObject, Sendable {
    /// The finalized turn's exclusive transcript insertion boundary.
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)? { get set }
    var onSilence: (@Sendable (TimeInterval) -> Void)? { get set }
    /// Earliest unresolved speech on the session clock, or unknown while the provider cannot prove
    /// a boundary. Finalized lines must be published before advancing this state.
    var onTranscriptionWorkChanged: (@Sendable (TranscriptionWorkState) -> Void)? { get set }
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)? { get set }
    var onTerminalFailure: (@Sendable (ProviderFailure) -> Void)? { get set }
    /// Content-free: never exposes amplitude or PCM.
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
    /// Ignores credentials the session doesn't use. Must not disturb a healthy connection; the new
    /// key applies on the next reconnect.
    func updateAPIKey(_ apiKey: String, for credential: Credential)
}

public extension TranscriptionSession {
    /// Providers with their own turn detector ignore capture-side speech edges.
    func recordLocalSpeechEvent(
        _ event: LocalSpeechEvent,
        throughSequenceNumber: UInt64
    ) {}

    /// On-device providers hold no credential to replace.
    func updateAPIKey(_ apiKey: String, for credential: Credential) {}
}
