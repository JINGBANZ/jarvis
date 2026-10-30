import Foundation

/// Turns Deepgram's stream of settled segments into whole utterances and tracks whether any speech
/// is still unresolved. Design: wiki/architecture.md#models-and-apis
///
/// Speech counts as unresolved while settled words wait for their utterance to close, while an
/// utterance is being published, and while speech began after everything finalized so far.
/// `UtteranceEnd` can describe an earlier gap after newer speech has begun, so it closes only the
/// words up to its boundary.
public struct DeepgramUtteranceAssembler: Sendable {
    /// Floating-point slack when comparing Deepgram's audio times.
    private static let tolerance: TimeInterval = 0.01

    private var segments: [(text: String, end: TimeInterval)] = []
    /// Audio time through which Deepgram has finalized, words or no words.
    private var finalizedThrough = -TimeInterval.infinity
    /// The latest start of speech that Deepgram has heard but not necessarily finalized.
    private var latestSpeechStart: TimeInterval?
    private var publishing = 0

    public init() {}

    public var hasUnresolvedSpeech: Bool {
        guard segments.isEmpty, publishing == 0 else { return true }
        guard let latestSpeechStart else { return false }
        return latestSpeechStart >= finalizedThrough - Self.tolerance
    }

    /// The settled segments of the utterance this event closed, oldest first, or empty. A
    /// non-empty return is unresolved until `finishPublishing()`, so the caller can publish the
    /// utterance before speech is reported settled.
    public mutating func receive(_ event: DeepgramLiveSession.Event) -> [String] {
        switch event {
        case .results(let result):
            let text = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.isFinal else {
                // Interim text is speculative; only the fact that words were heard is kept.
                if !text.isEmpty { noteSpeech(startingAt: result.start) }
                return []
            }
            finalizedThrough = max(finalizedThrough, result.end)
            if !text.isEmpty {
                segments.append((text: text, end: result.lastWordEnd ?? result.end))
            }
            return result.speechFinal ? close(through: .infinity) : []
        case .utteranceEnd(let lastWordEnd):
            return close(through: lastWordEnd + Self.tolerance)
        case .speechStarted(let timestamp):
            noteSpeech(startingAt: timestamp)
            return []
        case .error, .other:
            return []
        }
    }

    /// Salvages every settled segment when the socket goes away. Same publishing contract as
    /// `receive(_:)`.
    public mutating func closeAll() -> [String] {
        latestSpeechStart = nil
        return close(through: .infinity)
    }

    public mutating func finishPublishing() {
        publishing = max(0, publishing - 1)
    }

    /// A new socket restarts Deepgram's audio clock. Publishing in flight is left to finish.
    public mutating func reset() {
        segments.removeAll()
        finalizedThrough = -.infinity
        latestSpeechStart = nil
    }

    private mutating func noteSpeech(startingAt start: TimeInterval) {
        latestSpeechStart = max(latestSpeechStart ?? start, start)
    }

    private mutating func close(through boundary: TimeInterval) -> [String] {
        let closed = segments.prefix { $0.end <= boundary }
        guard !closed.isEmpty else { return [] }
        segments.removeFirst(closed.count)
        publishing += 1
        return closed.map(\.text)
    }
}
