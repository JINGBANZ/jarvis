import Foundation

/// Derives a pending start for a provider that reports no per-utterance timing. The window opens at
/// the local speech onset, is capped by the moment the provider first reported recognizing, and
/// closes once nothing is left to resolve. It also gives a finalized utterance its spoken start
/// when the onset can only belong to that utterance.
public struct PendingSpeechWindow: Sendable {
    private var localSpeechActive = false
    private var localOnset: TimeInterval?
    private var recognitionObservedAt: TimeInterval?
    private var localEpisodeCount = 0
    private var onsetClaimed = false

    public init() {}

    /// An open window keeps its earliest onset: a later episode belongs to the same unresolved run.
    public mutating func recordLocalSpeech(active: Bool, at time: TimeInterval) {
        localSpeechActive = active
        guard active else { return }
        localEpisodeCount += 1
        guard localOnset == nil, time.isFinite, time >= 0 else { return }
        localOnset = time
    }

    /// Recognition cannot have begun before the speech it recognizes, so this only moves the start
    /// earlier. It never opens a window: speech the local detector missed stays unknown.
    public mutating func recordRecognitionObserved(at time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        recognitionObservedAt = min(recognitionObservedAt ?? time, time)
    }

    /// The spoken start of the utterance the provider just finalized, or nil to keep its arrival
    /// time. Only a window's first final with a single local episode gets the onset: a later final
    /// in a long run began after it, and with a second episode the first may have been recognized
    /// but never finalized. The recognition cap stays out for the same reason.
    public mutating func recordFinalized() -> TimeInterval? {
        defer { onsetClaimed = true }
        guard !onsetClaimed, localEpisodeCount == 1 else { return nil }
        return localOnset
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
        if !isRecognizing, queuedSince == nil, !localSpeechActive {
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
        localEpisodeCount = 0
        onsetClaimed = false
    }

    private var recognizedSince: TimeInterval? {
        localOnset.map { min($0, recognitionObservedAt ?? $0) }
    }
}
