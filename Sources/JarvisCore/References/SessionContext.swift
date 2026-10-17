import Foundation

public struct SessionContext: Equatable, Sendable {
    public let documentCatalog: DocumentCatalog?
    public let serialized: Data

    public init(documentCatalog: DocumentCatalog?) throws {
        self.documentCatalog = try documentCatalog?.validated()
        struct Sections: Encodable { let documentCatalog: DocumentCatalog? }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        serialized = try encoder.encode(Sections(documentCatalog: self.documentCatalog))
    }
}
