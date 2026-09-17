import Foundation

public struct PrepMaterialChunk: Sendable, Equatable {
    public let sourceDisplayName: String
    public let text: String

    public init(sourceDisplayName: String, text: String) {
        self.sourceDisplayName = sourceDisplayName
        self.text = text
    }
}
