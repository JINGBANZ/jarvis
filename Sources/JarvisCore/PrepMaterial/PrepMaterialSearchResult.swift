import Foundation

/// One relevant excerpt from the user's configured prep material, plus which source it came from.
public struct PrepMaterialSearchResult: Sendable, Equatable {
    public let sourceDisplayName: String
    public let text: String

    public init(sourceDisplayName: String, text: String) {
        self.sourceDisplayName = sourceDisplayName
        self.text = text
    }
}
