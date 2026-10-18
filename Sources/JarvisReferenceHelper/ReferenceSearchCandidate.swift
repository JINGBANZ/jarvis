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
                      query: String, deadline: ContinuousClock.Instant) async throws -> ReferenceSearchBatch {
        let db = try ReferenceDatabase(path: databasePath, readOnly: true)
        // Progress cancellation bounds expensive postings/ranking as well as IPC wait time.
        let cancellation = ReferenceQueryBudget(deadline: deadline)
        cancellation.install(on: db)
        defer { cancellation.remove(from: db) }
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        #if JARVIS_LIVE_E2E
        await ReferenceSearchIndex.barrier(home: URL(fileURLWithPath: databasePath).deletingLastPathComponent(), name: "search-before-readiness-query", deadline: deadline)
        #endif
        try cancellation.check()
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
        let names = try db.rows("""
            WITH names AS (
              SELECT document_id,name,CASE WHEN substr(name,-11)=' [' || substr(document_id,1,8) || ']'
                THEN substr(name,1,length(name)-11) ELSE name END AS base
              FROM session_documents WHERE session_id=?
                AND (? IS NULL OR document_id IN (SELECT value FROM json_each(?)))
            )
            SELECT document_id,name,base FROM names WHERE instr(?,reference_casefold(base))>0
            """, [session, subset, subset, ReferenceSearchTokenizer.folded(query)]).map { row -> (document: String, name: String, base: String) in
                guard let document = row[0], let name = row[1], let base = row[2] else { throw ReferenceStoreError.unavailable }
                return (document, name, base)
            }
        try cancellation.check()
        let scope = try ReferenceSearchNameScope(query: query, names: names, budget: cancellation)
        let named = try scope.documents.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let expression = ReferenceSearchTokenizer.matchExpression(scope.query) ?? "\"t0\""
        let candidates = try db.rows("""
            WITH eligible AS MATERIALIZED (
              SELECT sd.document_id,r.id AS revision_id,s.generation,sd.name,r.scalar_count
              FROM session_documents sd JOIN documents d ON d.id=sd.document_id
              JOIN revisions r ON r.id=coalesce(sd.pin,d.current_revision) AND r.ready=1 AND r.search_ready=1
              JOIN search_state s ON s.revision_id=r.id AND s.state='ready' AND s.version=?
              JOIN sessions session ON session.id=sd.session_id AND session.state='active'
              WHERE sd.session_id=? AND (? IS NULL OR sd.document_id IN (SELECT value FROM json_each(?)))
                AND sd.document_id NOT IN (SELECT value FROM json_each(?))
                AND (? IS NULL OR sd.document_id IN (SELECT value FROM json_each(?)))
            )
            SELECT e.document_id,e.revision_id,e.generation,e.name,p.section,coalesce(p.text,''),coalesce(p.offset,0),e.scalar_count,
                   1 AS priority,0 AS score,coalesce(p.ordinal,0) AS ordinal
            FROM eligible e LEFT JOIN passages p ON p.revision_id=e.revision_id AND p.generation=e.generation AND p.ordinal=0
            WHERE ? IS NOT NULL AND (p.id IS NOT NULL OR e.scalar_count=0)
              AND NOT EXISTS(SELECT 1 FROM chunks JOIN passages matched ON matched.id=chunks.rowid
                WHERE chunks MATCH ? AND matched.revision_id=e.revision_id AND matched.generation=e.generation)
            UNION ALL
            SELECT e.document_id,e.revision_id,e.generation,e.name,p.section,p.text,p.offset,e.scalar_count,
                   0 AS priority,bm25(chunks) AS score,p.ordinal
            FROM chunks JOIN passages p ON p.id=chunks.rowid
            JOIN eligible e ON e.revision_id=p.revision_id AND e.generation=p.generation
            WHERE chunks MATCH ?
            ORDER BY priority,score,document_id,ordinal LIMIT 4
            """, [ReferenceSearchIndex.version, session, subset, subset, excluded, named, named, named, expression, expression]).map { row in
                guard let document = row[0], let revision = row[1], let generation = row[2], let name = row[3],
                      let text = row[5], let offset = row[6].flatMap(Int.init), let total = row[7].flatMap(Int.init) else { throw ReferenceStoreError.unavailable }
                return Self(document: document, revision: revision, generation: generation, name: name,
                            section: row[4], text: text, offset: offset, total: total)
            }
        return ReferenceSearchBatch(candidates: candidates, states: states, metadataGeneration: metadataGeneration, query: scope.query)
    }

    func excerpt(query: String) -> (text: String, offset: Int) {
        let wanted = ReferenceSearchTokenizer.queryTerms(query)
        let match = ReferenceSearchTokenizer.terms(text).first { wanted.contains($0.value) }?.offset ?? 0
        let scalars = text.unicodeScalars
        let begin = max(0, match - 400)
        let start = scalars.index(scalars.startIndex, offsetBy: begin)
        let end = scalars.index(start, offsetBy: 2_000, limitedBy: scalars.endIndex) ?? scalars.endIndex
        return (String(scalars[start..<end]), offset + begin)
    }
}
