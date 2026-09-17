import Foundation

/// Streaming models only. The batch `gemini-3.5-transcribe` can't follow a live conversation.
public enum GeminiTranscriptionModel: String, CaseIterable, Codable, Sendable {
    case geminiTranscribeLive = "gemini-3.5-transcribe-live"

    public var displayName: String {
        switch self {
        case .geminiTranscribeLive: "Gemini 3.5 Transcribe Live"
        }
    }

    /// The Live API wants a `models/` resource name; the persisted raw value deliberately has none.
    public var wireModelName: String { "models/\(rawValue)" }
}
