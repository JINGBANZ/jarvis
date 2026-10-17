import Foundation
import JarvisCore

extension ReferenceDocumentStore {
    func search(_ request: ReferenceHelperRequest, _ payload: Payload) async throws -> Data {
        let session = try requireSession(request, payload)
        guard let app = payload.app_instance_id else { throw ReferenceStoreError.unknown_session }
        guard let query = payload.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.unicodeScalars.count <= 512 else { throw ReferenceStoreError.limit_exceeded }
        guard (payload.document_ids?.count ?? 0) <= 2_000 else { throw ReferenceStoreError.limit_exceeded }
        let subset = payload.document_ids.map { "," + $0.map { $0.uuidString.lowercased() }.joined(separator: ",") + "," }
        let eligible = try db.rows("""
            SELECT sd.document_id,sd.pin FROM session_documents sd
            JOIN revisions r ON r.id=sd.pin AND r.ready=1
            WHERE sd.session_id=? AND (? IS NULL OR instr(?,',' || sd.document_id || ',')>0)
            ORDER BY sd.document_id
            """, [session, subset, subset])
        let deadline = ContinuousClock.now + .seconds(2)
        var indexed = 0
        for row in eligible {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            guard let document = row[0], let revision = row[1] else { throw ReferenceStoreError.unavailable }
            if try db.scalar("SELECT 1 FROM chunks WHERE revision_id=? LIMIT 1", [revision]) == nil {
                let pagePayload = try JSONDecoder().decode(Payload.self, from: json([
                    "app_instance_id": app.uuidString,
                    "document_id": document, "offset": 0, "revision_id": revision,
                ]))
                let page = try JSONDecoder().decode(ReferenceReadResult.self, from: await read(request, pagePayload))
                guard diskBytes() + Int64(page.text.utf8.count) * 8 + 65_536 < Self.cacheTarget else { break }
                _ = try requireSession(request, payload)
                try db.transaction {
                    try db.execute("INSERT INTO chunks(revision_id,text) VALUES(?,?)", [revision, page.text])
                }
            }
            indexed += 1
            await Task.yield()
        }
        _ = try requireSession(request, payload)
        let literal = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let rows = try db.rows("""
            SELECT sd.document_id,r.id,chunks.text,r.scalar_count FROM chunks
            JOIN revisions r ON r.id=chunks.revision_id AND r.ready=1
            JOIN session_documents sd ON sd.pin=r.id AND sd.document_id=r.document_id
            WHERE chunks MATCH ? AND sd.session_id=?
              AND (? IS NULL OR instr(?,',' || sd.document_id || ',')>0)
            ORDER BY rank,sd.document_id LIMIT 3
            """, [literal, session, subset, subset])
        let hits: [[String: Any]] = rows.map { row in
            let text = String(String.UnicodeScalarView((row[2] ?? "").unicodeScalars.prefix(2_000)))
            return ["document_id": row[0] ?? "", "revision_id": row[1] ?? "", "text": text,
                    "next_offset": text.unicodeScalars.count, "total_scalars": Int(row[3] ?? "0") ?? 0,
                    "search_ready": false]
        }
        // This packaging proof indexes pinned first pages; phase 3 supplies complete retrieval.
        return try json(["status": "partial", "hits": hits, "complete": false,
                         "coverage": ["pinned_documents": eligible.count, "indexed_first_pages": indexed,
                                      "full_document_index": false]])
    }
}
