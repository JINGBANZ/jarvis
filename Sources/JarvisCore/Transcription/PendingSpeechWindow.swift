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
    private var localEnd: TimeInterval?

    public init() {}

    /// An open window keeps its earliest onset: a later episode belongs to the same unresolved run.
    public mutating func recordLocalSpeech(active: Bool, at time: TimeInterval) {
        if active, !localSpeechActive, onsetClaimed { close() }
        localSpeechActive = active
        guard active else {
            if time.isFinite { localEnd = time }
            return
        }
        localEnd = nil
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

    /// A final can precede local endpoint detection. Wait for that measured end; recognition
    /// arrival is never substituted. Multiple unresolved episodes cannot be assigned one range.
    public var awaitsSpeechEnd: Bool {
        !onsetClaimed && localEpisodeCount == 1 && localOnset != nil && localSpeechActive
    }

    public mutating func takeFinalizedInterval() -> SpeechInterval? {
        guard !awaitsSpeechEnd else { return nil }
        defer { onsetClaimed = true }
        guard !onsetClaimed, localEpisodeCount == 1, let localOnset, let localEnd else { return nil }
        return SpeechInterval(startedAt: localOnset, endedAt: localEnd)
    }

    public mutating func recordRecognitionFinalized() {
        onsetClaimed = true
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
        if !isRecognizing, queuedSince == nil, !localSpeechActive, onsetClaimed {
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
        localEnd = nil
        recognitionObservedAt = nil
        localEpisodeCount = 0
        onsetClaimed = false
    }

    private var recognizedSince: TimeInterval? {
        localOnset.map { min($0, recognitionObservedAt ?? $0) }
    }
}
