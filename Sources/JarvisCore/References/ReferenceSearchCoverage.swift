import Foundation

public struct ReferenceSearchCoverage: Codable, Equatable, Sendable {
    public let eligibleDocuments: Int
    public let searchedDocuments: Int
    public let omissions: [String: Int]
    public let metadataGeneration: Int
    public let indexVersion: String

    public init(eligibleDocuments: Int, searchedDocuments: Int, omissions: [String: Int], metadataGeneration: Int, indexVersion: String) {
        self.eligibleDocuments = eligibleDocuments; self.searchedDocuments = searchedDocuments
        self.omissions = omissions; self.metadataGeneration = metadataGeneration; self.indexVersion = indexVersion
    }

    enum CodingKeys: String, CodingKey {
        case eligibleDocuments = "eligible_documents", searchedDocuments = "searched_documents", omissions
        case metadataGeneration = "metadata_generation", indexVersion = "index_version"
    }
}
