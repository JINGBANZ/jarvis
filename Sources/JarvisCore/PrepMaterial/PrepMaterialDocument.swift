import Foundation

public struct PrepMaterialDocument: Sendable {
    public let id: String
    public let sourceDisplayName: String
    public let text: String

    public init(sourceDisplayName: String, text: String) {
        self.id = UUID().uuidString
        self.sourceDisplayName = sourceDisplayName
        self.text = text
    }
}
