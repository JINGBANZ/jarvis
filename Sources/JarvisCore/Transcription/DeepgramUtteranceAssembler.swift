import Foundation

/// Turns Deepgram's stream of settled segments into whole utterances and tracks whether any speech
/// is still unresolved. Design: wiki/architecture.md#models-and-apis
///
/// Speech counts as unresolved while settled words wait for their utterance to close, while an
/// utterance is being published, while an interim heard words beyond everything finalized so far,
/// and while speech began after it. A final can cover less than the interim before it, and
/// `UtteranceEnd` can describe an earlier gap after newer speech has begun, so it closes only the
/// words up to its boundary. Word timing, not the interim's window, marks heard speech, so trailing
/// silence never counts.
///
/// Times are per socket. Events from any socket but the one passed to `reset(socket:)` are
/// ignored, so a retired socket's late callback cannot mix its clock into the replacement's.
public struct DeepgramUtteranceAssembler: Sendable {
    /// Floating-point slack when comparing Deepgram's audio times.
    private static let tolerance: TimeInterval = 0.01

    private var segments: [(text: String, end: TimeInterval)] = []
    /// Audio time through which Deepgram has finalized, words or no words.
    private var finalizedThrough = -TimeInterval.infinity
    /// The end of the latest word an interim result heard.
    private var latestHeardWordEnd: TimeInterval?
    /// The latest onset `SpeechStarted` reported.
    private var latestSpeechStart: TimeInterval?
    private var socket: Int?
    private var publishing = 0

    public init() {}

    public var hasUnresolvedSpeech: Bool {
        guard segments.isEmpty, publishing == 0 else { return true }
        if let latestHeardWordEnd, latestHeardWordEnd > finalizedThrough + Self.tolerance { return true }
        if let latestSpeechStart, latestSpeechStart >= finalizedThrough - Self.tolerance { return true }
        return false
    }

    /// The settled segments of the utterance this event closed, oldest first, or empty. A
    /// non-empty return is unresolved until `finishPublishing()`, so the caller can publish the
    /// utterance before speech is reported settled.
    public mutating func receive(_ event: DeepgramLiveSession.Event, socket: Int) -> [String] {
        guard socket == self.socket else { return [] }
        switch event {
        case .results(let result):
            let text = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.isFinal else {
                // Interim text is speculative; only how far its words reach is kept.
                if !text.isEmpty {
                    let wordEnd = result.lastWordEnd ?? result.end
                    latestHeardWordEnd = max(latestHeardWordEnd ?? wordEnd, wordEnd)
                }
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
            latestSpeechStart = max(latestSpeechStart ?? timestamp, timestamp)
            return []
        case .error, .other:
            return []
        }
    }

    /// Salvages every settled segment when the socket goes away. Same publishing contract as
    /// `receive(_:socket:)`.
    public mutating func closeAll() -> [String] {
        latestHeardWordEnd = nil
        latestSpeechStart = nil
        return close(through: .infinity)
    }

    public mutating func finishPublishing() {
        publishing = max(0, publishing - 1)
    }

    /// A new socket restarts Deepgram's audio clock. Publishing in flight is left to finish.
    public mutating func reset(socket: Int) {
        self.socket = socket
        segments.removeAll()
        finalizedThrough = -.infinity
        latestHeardWordEnd = nil
        latestSpeechStart = nil
    }

    private mutating func close(through boundary: TimeInterval) -> [String] {
        let closed = segments.prefix { $0.end <= boundary }
        guard !closed.isEmpty else { return [] }
        segments.removeFirst(closed.count)
        publishing += 1
        return closed.map(\.text)
    }
}
