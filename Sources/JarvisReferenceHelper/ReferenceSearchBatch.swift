import Foundation

struct ReferenceSearchBatch: Sendable {
    let candidates: [ReferenceSearchCandidate]
    let states: [(document: String, state: String)]
    let metadataGeneration: Int
    let query: String
}
