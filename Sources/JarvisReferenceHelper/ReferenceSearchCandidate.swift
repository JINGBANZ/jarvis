import Foundation
import JarvisCore

struct ReferenceSearchCandidate: Sendable {
    let document: String
    let revision: String
    let generation: String
    let name: String
    let section: String?
    let text: String
    let offset: Int
    let total: Int

    static func query(databasePath: String, session: String, subset: String?, excluded: String,
                      expression: String, query: String, deadline: ContinuousClock.Instant) throws -> ReferenceSearchBatch {
        let db = try ReferenceDatabase(path: databasePath, readOnly: true)
        // Progress cancellation bounds expensive postings/ranking as well as IPC wait time.
        let cancellation = ReferenceQueryBudget(deadline: deadline)
        cancellation.install(on: db)
        defer { cancellation.remove(from: db) }
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        let states = try db.rows("""
            SELECT sd.document_id,CASE WHEN r.id IS NULL THEN 'preparing'
              WHEN s.state='ready' AND s.version=? AND r.search_ready=1 THEN 'ready'
              ELSE coalesce(s.state,'preparing') END
            FROM session_documents sd JOIN documents d ON d.id=sd.document_id
            LEFT JOIN revisions r ON r.id=coalesce(sd.pin,d.current_revision) AND r.ready=1
            LEFT JOIN search_state s ON s.revision_id=r.id
            WHERE sd.session_id=? AND (? IS NULL OR sd.document_id IN (SELECT value FROM json_each(?)))
            """, [ReferenceSearchIndex.version, session, subset, subset]).map { row -> (document: String, state: String) in
                guard let document = row[0], let state = row[1] else { throw ReferenceStoreError.unavailable }
                return (document, state)
            }
        let metadataGeneration = Int(try db.scalar("SELECT generation FROM sessions WHERE id=?", [session]) ?? "0") ?? 0
        let candidates = try db.rows("""
            WITH eligible AS MATERIALIZED (
              SELECT sd.document_id,r.id AS revision_id,s.generation,sd.name,r.scalar_count
              FROM session_documents sd JOIN documents d ON d.id=sd.document_id
              JOIN revisions r ON r.id=coalesce(sd.pin,d.current_revision) AND r.ready=1 AND r.search_ready=1
              JOIN search_state s ON s.revision_id=r.id AND s.state='ready' AND s.version=?
              JOIN sessions session ON session.id=sd.session_id AND session.state='active'
              WHERE sd.session_id=? AND (? IS NULL OR sd.document_id IN (SELECT value FROM json_each(?)))
                AND sd.document_id NOT IN (SELECT value FROM json_each(?))
            )
            SELECT e.document_id,e.revision_id,e.generation,e.name,p.section,p.text,p.offset,e.scalar_count,
                   -1 AS priority,0 AS score,p.ordinal
            FROM eligible e JOIN passages p ON p.revision_id=e.revision_id AND p.generation=e.generation AND p.ordinal=0
            WHERE lower(e.name)=lower(?) OR lower(e.name)=lower(?) || ' [' || substr(e.document_id,1,8) || ']'
            UNION ALL
            SELECT e.document_id,e.revision_id,e.generation,e.name,p.section,p.text,p.offset,e.scalar_count,
                   0 AS priority,bm25(chunks) AS score,p.ordinal
            FROM chunks JOIN passages p ON p.id=chunks.rowid
            JOIN eligible e ON e.revision_id=p.revision_id AND e.generation=p.generation
            WHERE chunks MATCH ?
              AND NOT(lower(e.name)=lower(?) OR lower(e.name)=lower(?) || ' [' || substr(e.document_id,1,8) || ']')
            ORDER BY priority,score,document_id,ordinal LIMIT 4
            """, [ReferenceSearchIndex.version, session, subset, subset, excluded, query, query, expression, query, query]).map { row in
                guard let document = row[0], let revision = row[1], let generation = row[2], let name = row[3],
                      let text = row[5], let offset = row[6].flatMap(Int.init), let total = row[7].flatMap(Int.init) else { throw ReferenceStoreError.unavailable }
                return Self(document: document, revision: revision, generation: generation, name: name,
                            section: row[4], text: text, offset: offset, total: total)
            }
        return ReferenceSearchBatch(candidates: candidates, states: states, metadataGeneration: metadataGeneration)
    }

    func excerpt(query: String) -> (text: String, offset: Int) {
        let wanted = Set(ReferenceSearchTokenizer.terms(query).map(\.value))
        let match = ReferenceSearchTokenizer.terms(text).first { wanted.contains($0.value) }?.offset ?? 0
        let scalars = text.unicodeScalars
        let begin = max(0, match - 400)
        let start = scalars.index(scalars.startIndex, offsetBy: begin)
        let end = scalars.index(start, offsetBy: 2_000, limitedBy: scalars.endIndex) ?? scalars.endIndex
        return (String(scalars[start..<end]), offset + begin)
    }
}
