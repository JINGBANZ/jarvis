import Foundation
import JarvisCore

@MainActor
final class HelperDocumentSession: DocumentSession {
    nonisolated let sessionID: UUID
    private weak var library: ReferenceLibrary?

    init(sessionID: UUID, library: ReferenceLibrary) {
        self.sessionID = sessionID; self.library = library
    }

    func list(query: String?, cursor: Int?) async throws -> ReferenceListResult {
        var payload: [String: Any] = [:]
        payload["query"] = query; payload["cursor"] = cursor
        return try await perform("list", payload: payload)
    }

    func read(documentID: UUID, offset: Int, revisionID: String?) async throws -> ReferenceReadResult {
        var payload: [String: Any] = ["document_id": documentID.uuidString.lowercased(), "offset": offset]
        payload["revision_id"] = revisionID
        return try await perform("read", payload: payload)
    }

    func search(query: String, documentIDs: [UUID]?) async throws -> ReferenceSearchResult {
        var payload: [String: Any] = ["query": query]
        payload["document_ids"] = documentIDs?.map { $0.uuidString.lowercased() }
        return try await perform("search", payload: payload)
    }

    private func perform<T: Decodable>(_ operation: String, payload: [String: Any]) async throws -> T {
        guard let library else { throw ReferenceAccessFailure(reason: .released) }
        return try JSONDecoder().decode(T.self, from: await library.request(operation, sessionID: sessionID, payload: payload))
    }
}
