import Foundation

public struct ReferenceReadResult: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let revisionID: String
    public let text: String
    public let nextOffset: Int
    public let totalScalars: Int
    public let searchReady: Bool

    public init(documentID: UUID, revisionID: String, text: String, nextOffset: Int, totalScalars: Int, searchReady: Bool) {
        self.documentID = documentID; self.revisionID = revisionID; self.text = text
        self.nextOffset = nextOffset; self.totalScalars = totalScalars; self.searchReady = searchReady
    }

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id", revisionID = "revision_id", text
        case nextOffset = "next_offset", totalScalars = "total_scalars", searchReady = "search_ready"
    }
}
