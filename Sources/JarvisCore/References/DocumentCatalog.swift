import Foundation

public struct DocumentCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let documentID: UUID
        public let name: String
        public let format: String

        public init(documentID: UUID, name: String, format: String) {
            self.documentID = documentID
            self.name = name
            self.format = format
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(documentID.uuidString.lowercased(), forKey: .documentID)
            try container.encode(name, forKey: .name)
            try container.encode(format, forKey: .format)
        }

        enum CodingKeys: String, CodingKey {
            case documentID = "document_id", name, format
        }
    }

    public static let maximumEntries = 200
    public static let maximumBytes = 16 * 1024
    public let entries: [Entry]
    public let totalCount: Int
    public let omittedCount: Int

    enum CodingKeys: String, CodingKey {
        case entries, totalCount = "total_count", omittedCount = "omitted_count"
    }

    private init(entries: [Entry], totalCount: Int) {
        self.entries = entries
        self.totalCount = totalCount
        omittedCount = totalCount - entries.count
    }

    public static func bounded(_ members: [Entry]) throws -> DocumentCatalog {
        try bounded(members, totalCount: members.count)
    }

    public static func bounded(_ members: [Entry], totalCount: Int) throws -> DocumentCatalog {
        guard totalCount >= members.count else { throw ReferenceProtocolError.malformed }
        let ordered = members.sorted { $0.documentID.uuidString < $1.documentID.uuidString }
        var entries: [Entry] = []
        for entry in ordered.prefix(maximumEntries) {
            let candidate = DocumentCatalog(entries: entries + [entry], totalCount: totalCount)
            guard try candidate.serialized().count <= maximumBytes else { break }
            entries.append(entry)
        }
        return DocumentCatalog(entries: entries, totalCount: totalCount)
    }

    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func validated() throws -> DocumentCatalog {
        guard entries.count <= Self.maximumEntries, totalCount >= entries.count,
              omittedCount == totalCount - entries.count,
              Set(entries.map(\.documentID)).count == entries.count,
              entries.allSatisfy({ !$0.name.contains("/") && !$0.name.contains("\\") && !$0.format.contains("/") }),
              try serialized().count <= Self.maximumBytes else { throw ReferenceProtocolError.malformed }
        return self
    }
}
