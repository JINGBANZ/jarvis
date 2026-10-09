import Foundation

public struct PrepMaterialSearchResult: Sendable, Equatable {
    public let sourceDisplayName: String
    public let text: String
    public let documentID: String?

    public init(sourceDisplayName: String, text: String, documentID: String? = nil) {
        self.documentID = documentID
        self.sourceDisplayName = sourceDisplayName
        self.text = text
    }
}
