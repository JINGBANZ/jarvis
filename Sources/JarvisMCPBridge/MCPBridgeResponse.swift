import Foundation

struct MCPBridgeResponse: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case capture
        case terminal
    }

    let ok: Bool
    let kind: Kind?
    let imageBase64: String?
    let recognizedText: String?
    let error: String?

    static func capture(imageBase64: String?, recognizedText: String?) -> Self {
        .init(
            ok: true,
            kind: .capture,
            imageBase64: imageBase64,
            recognizedText: recognizedText,
            error: nil)
    }

    static let terminal = Self(
        ok: true,
        kind: .terminal,
        imageBase64: nil,
        recognizedText: nil,
        error: nil)

    static func failure(_ error: String) -> Self {
        .init(
            ok: false,
            kind: nil,
            imageBase64: nil,
            recognizedText: nil,
            error: error)
    }
}
