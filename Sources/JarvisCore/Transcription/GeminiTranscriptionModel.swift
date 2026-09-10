import Foundation

/// A Gemini speech-to-text model Jarvis can select. Only the live/streaming model applies — Jarvis
/// coaches a conversation as it happens, so the batch `gemini-3.5-transcribe` has no place here.
public enum GeminiTranscriptionModel: String, CaseIterable, Codable, Sendable {
    case geminiTranscribeLive = "gemini-3.5-transcribe-live"

    public var displayName: String {
        switch self {
        case .geminiTranscribeLive: "Gemini 3.5 Transcribe Live"
        }
    }

    /// The Live API addresses models by resource name, so the wire value carries a `models/` prefix
    /// the persisted raw value deliberately does not.
    public var wireModelName: String { "models/\(rawValue)" }
}
