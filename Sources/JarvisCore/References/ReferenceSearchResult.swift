import Foundation

public struct ReferenceSearchResult: Codable, Equatable, Sendable {
    public let hits: [ReferenceReadResult]
    public let complete: Bool

    public init(hits: [ReferenceReadResult], complete: Bool) {
        self.hits = hits; self.complete = complete
    }
}
