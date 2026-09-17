import Foundation

public enum GeminiTranscriptionMode: String, CaseIterable, Codable, Sendable {
    case verbatim
    case smart

    public var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .smart: "Smart"
        }
    }

    public var wireValue: String { rawValue.uppercased() }
}
