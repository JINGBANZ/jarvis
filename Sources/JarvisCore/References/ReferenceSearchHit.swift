import Foundation

public struct ReferenceSearchHit: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let revisionID: String
    public let name: String
    public let section: String?
    public let text: String
    public let offset: Int
    public let nextOffset: Int
    public let totalScalars: Int

    public init(documentID: UUID, revisionID: String, name: String, section: String?, text: String,
                offset: Int, nextOffset: Int, totalScalars: Int) {
        self.documentID = documentID; self.revisionID = revisionID; self.name = name; self.section = section
        self.text = text; self.offset = offset; self.nextOffset = nextOffset; self.totalScalars = totalScalars
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentID.uuidString.lowercased(), forKey: .documentID)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(section, forKey: .section)
        try container.encode(text, forKey: .text)
        try container.encode(offset, forKey: .offset)
        try container.encode(nextOffset, forKey: .nextOffset)
        try container.encode(totalScalars, forKey: .totalScalars)
    }

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id", revisionID = "revision_id", name, section, text, offset
        case nextOffset = "next_offset", totalScalars = "total_scalars"
    }
}
