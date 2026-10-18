import Foundation

extension ReferenceDocumentStore {
    func pageForPinnedRevision(id: String, offset: Int, deadline: ContinuousClock.Instant? = nil) async throws -> ReferenceRevisionPage {
        guard pageReaders < 2 else { throw ReferenceStoreError.preparing }
        pageReaders += 1
        defer { pageReaders -= 1 }
        let path = databasePath
        let loader = Task.detached(priority: .userInitiated) {
            try await ReferenceRevisionPage.load(databasePath: path, revision: id, offset: offset, deadline: deadline)
        }
        return try await withTaskCancellationHandler { try await loader.value } onCancel: { loader.cancel() }
    }

    func read(_ request: ReferenceHelperRequest, _ payload: Payload) async throws -> Data {
        let session = try requireSession(request, payload)
        guard let document = payload.document_id?.uuidString.lowercased(),
              let member = try db.rows("SELECT name,pin FROM session_documents WHERE session_id=? AND document_id=?", [session, payload.document_id?.uuidString.lowercased()]).first,
              let name = member[0] else { throw ReferenceStoreError.unknown_document }
        let offset = payload.offset ?? 0
        guard offset >= 0 else { throw ReferenceStoreError.invalid_offset }
        var revision: String
        if let pin = member[1] { revision = pin }
        else { revision = try await prepare(document: document, session: session, waiter: request.id, background: false) }
        if let requested = payload.revision_id, requested != revision { throw ReferenceStoreError.revision_mismatch }
        var page = try await pageForPinnedRevision(id: revision, offset: offset)
        try Task.checkCancellation()
        _ = try requireSession(request, payload)
        guard let current = try db.rows("SELECT pin FROM session_documents WHERE session_id=? AND document_id=?", [session, document]).first else { throw ReferenceStoreError.unknown_document }
        if let pin = current[0], pin != revision {
            revision = pin
            if let requested = payload.revision_id, requested != revision { throw ReferenceStoreError.revision_mismatch }
            page = try await pageForPinnedRevision(id: revision, offset: offset)
            _ = try requireSession(request, payload)
        } else if current[0] == nil {
            guard let (capture, url, root) = revisionCaptures[revision] else { throw ReferenceStoreError.unavailable }
            let validation = Task.detached(priority: .userInitiated) {
                try ReferenceSourceCapture.validate(capture: capture, originalURL: url, root: root)
            }
            try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
            try Task.checkCancellation()
            _ = try requireSession(request, payload)
            try db.transaction {
                guard try db.scalar("SELECT ready FROM revisions WHERE id=?", [revision]) == "1" else { throw ReferenceStoreError.unavailable }
                if let pin = try db.scalar("SELECT pin FROM session_documents WHERE session_id=? AND document_id=?", [session, document]), pin != revision { throw ReferenceStoreError.preparing }
                try db.execute("UPDATE session_documents SET pin=? WHERE session_id=? AND document_id=? AND pin IS NULL", [revision, session, document])
                try db.execute("UPDATE revisions SET last_used=strftime('%s','now') WHERE id=?", [revision])
            }
        }
        return try json(["status": "ok", "document_id": document, "revision_id": revision, "name": name,
                         "text": page.text, "offset": offset, "next_offset": offset + page.text.unicodeScalars.count,
                         "total_scalars": page.totalScalars, "search_ready": try db.scalar("SELECT search_ready FROM revisions WHERE id=?", [revision]) == "1"])
    }
}
