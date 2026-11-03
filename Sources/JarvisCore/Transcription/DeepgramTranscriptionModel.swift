import Foundation

/// Streaming models only. Nova-3 is the newest Deepgram streaming model with Mandarin; Flux has none.
public enum DeepgramTranscriptionModel: String, CaseIterable, Codable, Sendable {
    case nova3 = "nova-3"

    public var displayName: String {
        switch self {
        case .nova3: "Deepgram Nova-3"
        }
    }
}
