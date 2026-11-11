import Foundation

/// Derives a pending start for a provider that reports no per-utterance timing. The window opens at
/// the local speech onset, is capped by the moment the provider first reported recognizing, and
/// closes once nothing is left to resolve. Transcript timing is resolved separately.
public struct PendingSpeechWindow: Sendable {
    private var localSpeechActive = false
    private var localOnset: TimeInterval?
    private var recognitionObservedAt: TimeInterval?
    private var recognitionFinalized = false

    public init() {}

    public mutating func recordLocalSpeech(_ event: LocalSpeechEvent) {
        let activity = event.activity
        recordLocalSpeech(active: activity.active, at: activity.at)
    }

    /// An open window keeps its earliest onset: a later episode belongs to the same unresolved run.
    public mutating func recordLocalSpeech(active: Bool, at time: TimeInterval) {
        if active, !localSpeechActive, recognitionFinalized { close() }
        localSpeechActive = active
        guard active else { return }
        guard localOnset == nil, time.isFinite, time >= 0 else { return }
        localOnset = time
    }

    /// Recognition cannot have begun before the speech it recognizes, so this only moves the start
    /// earlier. It never opens a window: speech the local detector missed stays unknown.
    public mutating func recordRecognitionObserved(at time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        recognitionObservedAt = min(recognitionObservedAt ?? time, time)
    }

    public mutating func recordRecognitionFinalized() {
        recognitionFinalized = true
    }

    public mutating func reset() {
        localSpeechActive = false
        close()
    }

    /// The earliest unresolved start across the audio still queued and the utterance being
    /// recognized. An utterance with no local onset leaves the whole stream unknown.
    public mutating func state(
        queuedSince: TimeInterval?,
        isRecognizing: Bool
    ) -> TranscriptionWorkState {
        if !isRecognizing, queuedSince == nil, !localSpeechActive, recognitionFinalized {
            close()
        }
        guard isRecognizing else {
            return queuedSince.map { .pending(since: $0) } ?? .settled
        }
        guard let recognizedSince else { return .pending(since: nil) }
        return .pending(since: min(recognizedSince, queuedSince ?? recognizedSince))
    }

    private mutating func close() {
        localOnset = nil
        recognitionObservedAt = nil
        recognitionFinalized = false
    }

    private var recognizedSince: TimeInterval? {
        localOnset.map { min($0, recognitionObservedAt ?? $0) }
    }
}
