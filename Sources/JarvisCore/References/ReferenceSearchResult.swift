import Foundation

public struct ReferenceSearchResult: Codable, Equatable, Sendable {
    public let hits: [ReferenceSearchHit]
    public let complete: Bool
    public let truncated: Bool
    public let coverage: ReferenceSearchCoverage

    public init(hits: [ReferenceSearchHit], complete: Bool, truncated: Bool, coverage: ReferenceSearchCoverage) {
        self.hits = hits; self.complete = complete; self.truncated = truncated; self.coverage = coverage
    }
}
