import Foundation

/// How literally Gemini transcribes speech. Verbatim preserves the raw utterance; smart removes
/// filler words and formats the output, which reads better but is no longer what was said.
public enum GeminiTranscriptionMode: String, CaseIterable, Codable, Sendable {
    case verbatim
    case smart

    public var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .smart: "Smart"
        }
    }

    /// The wire enum is uppercase.
    public var wireValue: String { rawValue.uppercased() }
}
