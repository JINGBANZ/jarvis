import Foundation

public protocol DocumentSession: AnyObject, Sendable {
    var sessionID: UUID { get }
    func list(query: String?, cursor: Int?) async throws -> ReferenceListResult
    func read(documentID: UUID, offset: Int, revisionID: String?) async throws -> ReferenceReadResult
    func search(query: String, documentIDs: [UUID]?) async throws -> ReferenceSearchResult
}
