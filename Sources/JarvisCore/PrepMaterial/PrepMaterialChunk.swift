import Foundation

/// One indexed unit of a prep-material source: a bounded span of already-extracted plain text plus
/// which source it came from. Chunking happens once when the index is built; scoring operates over
/// these.
public struct PrepMaterialChunk: Sendable, Equatable {
    public let sourceDisplayName: String
    public let text: String

    public init(sourceDisplayName: String, text: String) {
        self.sourceDisplayName = sourceDisplayName
        self.text = text
    }
}
