import Foundation

public struct ReferenceListResult: Codable, Equatable, Sendable {
    public let entries: [DocumentCatalog.Entry]
    public let nextCursor: Int?
    public let totalCount: Int

    public init(entries: [DocumentCatalog.Entry], nextCursor: Int?, totalCount: Int) {
        self.entries = entries; self.nextCursor = nextCursor; self.totalCount = totalCount
    }

    enum CodingKeys: String, CodingKey {
        case entries, nextCursor = "next_cursor", totalCount = "total_count"
    }
}
