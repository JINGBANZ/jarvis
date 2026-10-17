import Foundation
import JarvisCore

extension ReferenceDocumentStore {
    func search(_ request: ReferenceHelperRequest, _ payload: Payload) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(2)
        let session = try requireSession(request, payload)
        guard let query = payload.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.unicodeScalars.count <= 512 else { throw ReferenceStoreError.limit_exceeded }
        guard (payload.document_ids?.count ?? 0) <= 2_000 else { throw ReferenceStoreError.limit_exceeded }
        let subset = try payload.document_ids.map { String(decoding: try JSONEncoder().encode($0.map { $0.uuidString.lowercased() }), as: UTF8.self) }
        let expression = ReferenceSearchTokenizer.matchExpression(query) ?? "\"t0\""
        var lastBatch = ReferenceSearchBatch(candidates: [], states: [], metadataGeneration: 0)
        var excluded: [String: String] = [:]
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            _ = try requireSession(request, payload)
            let path = databasePath
            let exclusion = String(decoding: try JSONEncoder().encode(excluded.keys.sorted()), as: UTF8.self)
            let lookup = Task.detached(priority: .userInitiated) {
                return try ReferenceSearchCandidate.query(databasePath: path, session: session, subset: subset,
                                                          excluded: exclusion, expression: expression, query: query, deadline: deadline)
            }
            let batch: ReferenceSearchBatch
            do { batch = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() } }
            catch {
                if ContinuousClock.now >= deadline { break }
                throw error
            }
            lastBatch = batch
            let candidates = batch.candidates
            var finalized: [(ReferenceSearchCandidate, ReferenceSearchHit)] = []
            var retry = false
            await ReferenceSearchIndex.barrier(home: home, name: "search-before-validation")
            for candidate in candidates.prefix(3) {
                guard ContinuousClock.now < deadline else { retry = true; break }
                do {
                    try await validateSearchCandidate(candidate, session: session)
                    let excerpt = candidate.excerpt(query: query)
                    let page = try await pageForPinnedRevision(id: candidate.revision, offset: excerpt.offset)
                    guard page.text.hasPrefix(excerpt.text), page.totalScalars == candidate.total else { throw ReferenceStoreError.unavailable }
                    guard let documentID = UUID(uuidString: candidate.document) else { throw ReferenceStoreError.unavailable }
                    finalized.append((candidate, ReferenceSearchHit(documentID: documentID, revisionID: candidate.revision,
                        name: candidate.name, section: candidate.section, text: excerpt.text, offset: excerpt.offset,
                        nextOffset: excerpt.offset + excerpt.text.unicodeScalars.count, totalScalars: candidate.total)))
                } catch is CancellationError { throw CancellationError() }
                catch ReferenceStoreError.superseded { retry = true }
                catch {
                    excluded[candidate.document] = (error as? ReferenceStoreError)?.rawValue ?? (error as? ReferenceConversionError)?.rawValue ?? "unavailable"
                    retry = true
                }
            }
            if retry { await Task.yield(); continue }
            await ReferenceSearchIndex.barrier(home: home, name: "search-before-pin")
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            do {
                try db.transaction {
                    _ = try requireSession(request, payload)
                    for (candidate, _) in finalized {
                        guard try db.scalar("""
                            SELECT 1 FROM session_documents sd JOIN documents d ON d.id=sd.document_id
                            JOIN revisions r ON r.id=? AND r.ready=1 AND r.search_ready=1
                            JOIN search_state s ON s.revision_id=r.id AND s.generation=? AND s.version=? AND s.state='ready'
                            WHERE sd.session_id=? AND sd.document_id=? AND coalesce(sd.pin,d.current_revision)=r.id
                            """, [candidate.revision, candidate.generation, ReferenceSearchIndex.version, session, candidate.document]) != nil else { throw ReferenceStoreError.superseded }
                        try db.execute("UPDATE session_documents SET pin=? WHERE session_id=? AND document_id=? AND pin IS NULL", [candidate.revision, session, candidate.document])
                        try db.execute("UPDATE revisions SET last_used=strftime('%s','now') WHERE id=?", [candidate.revision])
                    }
                }
            } catch ReferenceStoreError.superseded {
                await ReferenceSearchIndex.barrier(home: home, name: "search-after-conflict")
                await Task.yield(); continue
            }
            return try searchResult(session: session, batch: batch, hits: finalized.map(\.1), truncated: candidates.count > 3, excluded: excluded)
        }
        return try searchResult(session: session, batch: lastBatch, hits: [], truncated: false, excluded: excluded, timedOut: true)
    }

    func validateSearchCandidate(_ candidate: ReferenceSearchCandidate, session: String) async throws {
        guard let member = try db.rows("SELECT pin FROM session_documents WHERE session_id=? AND document_id=?", [session, candidate.document]).first else { throw ReferenceStoreError.unknown_document }
        if let pin = member[0] {
            guard pin == candidate.revision else { throw ReferenceStoreError.superseded }
            return
        }
        let source = try sourceLocation(document: candidate.document, session: session)
        guard let state = try db.scalar("SELECT source_state FROM revision_sources WHERE revision_id=?", [candidate.revision]) else {
            // A pre-index cache revision must be revalidated without pinning or trusting stale bytes.
            Task { _ = try? await self.prepare(document: candidate.document, session: session, waiter: UUID(), background: true) }
            throw ReferenceStoreError.preparing
        }
        let validation = Task.detached(priority: .userInitiated) {
            guard try ReferenceSourceCapture.statState(url: source.url, root: source.root) == state else { throw ReferenceStoreError.source_changed }
        }
        do { try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() } }
        catch {
            let document = candidate.document
            Task { _ = try? await self.prepare(document: document, session: session, waiter: UUID(), background: true) }
            throw error
        }
        _ = try requireActiveSession(session)
    }

    func requireActiveSession(_ session: String) throws {
        guard try db.scalar("SELECT state FROM sessions WHERE id=?", [session]) == "active" else { throw ReferenceStoreError.unknown_session }
    }

    func searchResult(session: String, batch: ReferenceSearchBatch, hits: [ReferenceSearchHit], truncated: Bool,
                      excluded: [String: String], timedOut: Bool = false) throws -> Data {
        try requireActiveSession(session)
        var omissions: [String: Int] = [:]
        var searched = 0
        for row in batch.states {
            if let reason = excluded[row.document] { omissions[reason, default: 0] += 1 }
            else if row.state == "ready" { searched += 1 }
            else { omissions[row.state, default: 0] += 1 }
        }
        if timedOut { omissions["deadline", default: 0] += 1 }
        let result = ReferenceSearchResult(hits: hits, complete: omissions.isEmpty, truncated: truncated,
            coverage: ReferenceSearchCoverage(eligibleDocuments: batch.states.count, searchedDocuments: searched,
                omissions: omissions, metadataGeneration: batch.metadataGeneration, indexVersion: ReferenceSearchIndex.version))
        let encoded = try JSONEncoder().encode(result)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["status"] = result.complete ? "ok" : "partial"
        return try json(object)
    }
}
