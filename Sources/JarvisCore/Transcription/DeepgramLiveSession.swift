import Foundation

/// The Deepgram live-transcription wire format. The API key travels in an `Authorization` header,
/// never the URL.
public enum DeepgramLiveSession {
    /// Times are seconds of audio since the socket opened; each socket restarts them at zero.
    public struct Result: Equatable, Sendable {
        public let transcript: String
        /// The words are settled.
        public let isFinal: Bool
        /// Deepgram's endpointing heard the utterance end.
        public let speechFinal: Bool
        public let start: TimeInterval
        public let end: TimeInterval
        public let lastWordEnd: TimeInterval?
        public let firstWordStart: TimeInterval?

        public init(
            transcript: String, isFinal: Bool, speechFinal: Bool,
            start: TimeInterval, end: TimeInterval, lastWordEnd: TimeInterval? = nil,
            firstWordStart: TimeInterval? = nil
        ) {
            self.transcript = transcript
            self.isFinal = isFinal
            self.speechFinal = speechFinal
            self.start = start
            self.end = end
            self.lastWordEnd = lastWordEnd
            self.firstWordStart = firstWordStart
        }
    }

    /// Keeps each contiguous span of sent audio until the socket closes, including spans for
    /// delayed finals. A final crossing a dropped capture chunk has no measured range.
    public struct AudioClock: Sendable {
        private struct Span: Sendable {
            let captureOrigin: TimeInterval
            let offset: TimeInterval
            var end: TimeInterval
        }

        private var spans: [Span] = []
        private var sentDuration: TimeInterval = 0
        private var expectedNextSequence: UInt64?
        private var durationKnown = true

        public init() {}

        public mutating func recordSentAudio(sequenceNumber: UInt64, capturedAt: TimeInterval, duration: TimeInterval) {
            guard durationKnown, duration.isFinite, duration > 0 else {
                durationKnown = false
                return
            }
            defer { sentDuration += duration; expectedNextSequence = sequenceNumber &+ 1 }
            guard capturedAt.isFinite, capturedAt >= 0 else { return }
            if let last = spans.last, last.end == sentDuration, expectedNextSequence == sequenceNumber {
                spans[spans.count - 1].end = sentDuration + duration
            } else {
                spans.append(Span(captureOrigin: capturedAt, offset: sentDuration, end: sentDuration + duration))
            }
        }

        public func sessionInterval(_ speech: SpeechInterval?) -> SpeechInterval? {
            guard durationKnown, let speech,
                  let span = spans.first(where: {
                      speech.startedAt >= $0.offset && speech.endedAt <= $0.end + 0.000_001
                  }) else { return nil }
            return SpeechInterval(startedAt: span.captureOrigin + speech.startedAt - span.offset,
                                  endedAt: span.captureOrigin + speech.endedAt - span.offset)
        }
    }

    public enum Event: Equatable, Sendable {
        case results(Result)
        /// A gap of `utterance_end_ms` followed the finalized word ending at `lastWordEnd`. It can
        /// arrive after newer speech has begun, so it closes only words up to that boundary.
        case utteranceEnd(lastWordEnd: TimeInterval)
        case speechStarted(at: TimeInterval)
        case error(description: String)
        case other
    }

    private static let endpoint = "wss://api.deepgram.com/v1/listen"

    /// Silence after speech that closes an utterance, in milliseconds.
    static let endpointingMilliseconds = 300
    /// Deepgram's documented minimum for `utterance_end_ms`.
    static let utteranceEndMilliseconds = 1_000

    /// One expected language selects it outright. Zero or several select Nova-3's multilingual mode,
    /// with the expected languages as soft hints.
    public static func connectURL(
        model: DeepgramTranscriptionModel, languages: [TranscriptionLanguage], sampleRate: Int
    ) -> URL {
        let languages = TranscriptionLanguage.canonicalizing(languages)
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "model", value: model.rawValue),
            URLQueryItem(name: "language", value: languages.count == 1 ? languages[0].deepgramHint : "multi"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: String(endpointingMilliseconds)),
            URLQueryItem(name: "utterance_end_ms", value: String(utteranceEndMilliseconds)),
            URLQueryItem(name: "vad_events", value: "true"),
        ]
        if languages.count > 1 {
            components.queryItems! += languages.map { URLQueryItem(name: "language_hint", value: $0.deepgramHint) }
        }
        return components.url!
    }

    public static func authorizationValue(apiKey: String) -> String { "Token \(apiKey)" }

    public static let keepAliveMessage = #"{"type":"KeepAlive"}"#
    public static let closeStreamMessage = #"{"type":"CloseStream"}"#

    /// Nil means drop the frame, not a transport failure.
    public static func parseEvent(_ bytes: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "Results":
            let channel = object["channel"] as? [String: Any]
            let alternative = (channel?["alternatives"] as? [[String: Any]])?.first
            let words = alternative?["words"] as? [[String: Any]] ?? []
            let start = number(object["start"]) ?? 0
            return .results(Result(
                transcript: alternative?["transcript"] as? String ?? "",
                isFinal: object["is_final"] as? Bool ?? false,
                speechFinal: object["speech_final"] as? Bool ?? false,
                start: start,
                end: start + (number(object["duration"]) ?? 0),
                lastWordEnd: words.last.flatMap { number($0["end"]) },
                firstWordStart: words.first.flatMap { number($0["start"]) }))
        case "UtteranceEnd":
            // Deepgram sends -1 when the words were finalized before the gap elapsed.
            guard let end = number(object["last_word_end"]), end >= 0 else { return .other }
            return .utteranceEnd(lastWordEnd: end)
        case "SpeechStarted":
            guard let timestamp = number(object["timestamp"]) else { return .other }
            return .speechStarted(at: timestamp)
        case "Error": return .error(description: object["description"] as? String ?? "")
        default: return .other
        }
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        (value as? NSNumber)?.doubleValue
    }

    /// Joins the settled segments of one utterance. Deepgram can space Mandarin words, which reads
    /// as broken text, so the gaps between CJK characters close. Latin words keep their spaces.
    public static func joinedTranscript(_ segments: [String], speaker: Speaker) -> String? {
        let text = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"(?<=[⺀-鿿＀-￯，。？！、：；])\s+(?=[⺀-鿿＀-￯，。？！、：；])"#,
                with: "", options: .regularExpression)
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
    }
}
