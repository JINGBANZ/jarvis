import Foundation

/// The Deepgram live-transcription wire format. The API key travels in an `Authorization` header,
/// never the URL.
public enum DeepgramLiveSession {
    public enum Event: Equatable, Sendable {
        /// `isFinal`: the words are settled. `speechFinal`: Deepgram's endpointing closed the utterance.
        case results(transcript: String, isFinal: Bool, speechFinal: Bool)
        /// The utterance gap `utterance_end_ms` asked for, sent when endpointing never fired.
        case utteranceEnd
        case speechStarted
        case error(description: String)
        case other
    }

    private static let endpoint = "wss://api.deepgram.com/v1/listen"

    /// Silence after speech that closes an utterance, in milliseconds.
    static let endpointingMilliseconds = 300
    /// Deepgram's documented minimum for `utterance_end_ms`.
    static let utteranceEndMilliseconds = 1_000

    public static func connectURL(
        model: DeepgramTranscriptionModel, language: TranscriptionLanguage, sampleRate: Int
    ) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "model", value: model.rawValue),
            URLQueryItem(name: "language", value: language.deepgramHint),
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
        return components.url!
    }

    public static func authorizationValue(apiKey: String) -> String { "Token \(apiKey)" }

    public static let keepAliveMessage = #"{"type":"KeepAlive"}"#
    public static let finalizeMessage = #"{"type":"Finalize"}"#
    public static let closeStreamMessage = #"{"type":"CloseStream"}"#

    /// Nil means drop the frame, not a transport failure.
    public static func parseEvent(_ bytes: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "Results":
            let channel = object["channel"] as? [String: Any]
            let alternatives = channel?["alternatives"] as? [[String: Any]]
            let transcript = alternatives?.first?["transcript"] as? String ?? ""
            return .results(
                transcript: transcript,
                isFinal: object["is_final"] as? Bool ?? false,
                speechFinal: object["speech_final"] as? Bool ?? false)
        case "UtteranceEnd": return .utteranceEnd
        case "SpeechStarted": return .speechStarted
        case "Error": return .error(description: object["description"] as? String ?? "")
        default: return .other
        }
    }

    /// Joins the settled segments of one utterance. Deepgram spaces Mandarin words, which reads
    /// as broken text, so the gaps between CJK characters close.
    public static func joinedTranscript(
        _ segments: [String], language: TranscriptionLanguage, speaker: Speaker
    ) -> String? {
        var text = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if language == .mandarinChinese {
            text = text.replacingOccurrences(
                of: #"(?<=[⺀-鿿＀-￯，。？！、：；])\s+(?=[⺀-鿿＀-￯，。？！、：；])"#,
                with: "", options: .regularExpression)
        }
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
    }
}
