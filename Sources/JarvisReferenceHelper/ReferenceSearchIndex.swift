import Foundation
import JarvisCore

struct ReferenceSearchIndex {
    static let version = "passages-1-" + ReferenceSearchTokenizer.version

    static func initialize(_ db: ReferenceDatabase) throws {
        try db.script("""
            CREATE TABLE IF NOT EXISTS revision_sources(revision_id TEXT PRIMARY KEY,source_state TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS search_configuration(id INTEGER PRIMARY KEY CHECK(id=1),version TEXT NOT NULL);
            """)
        if try db.scalar("SELECT version FROM search_configuration WHERE id=1") != version {
            try db.transaction {
                try db.script("""
                    DROP TABLE IF EXISTS chunks;
                    DROP TABLE IF EXISTS passages;
                    DROP TABLE IF EXISTS search_state;
                    CREATE TABLE search_state(revision_id TEXT PRIMARY KEY,generation TEXT NOT NULL,version TEXT NOT NULL,state TEXT NOT NULL,passage_count INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE passages(id INTEGER PRIMARY KEY,revision_id TEXT NOT NULL,generation TEXT NOT NULL,ordinal INTEGER NOT NULL,offset INTEGER NOT NULL,end_offset INTEGER NOT NULL,section TEXT,text TEXT NOT NULL);
                    CREATE UNIQUE INDEX passage_generation ON passages(revision_id,generation,ordinal);
                    CREATE VIRTUAL TABLE chunks USING fts5(revision_id UNINDEXED,generation UNINDEXED,text,tokenize='ascii');
                    UPDATE revisions SET search_ready=0;
                    """)
                try db.execute("INSERT INTO search_configuration VALUES(1,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version", [version])
            }
        }
        // An interrupted generation never becomes eligible after a restart.
        try db.transaction {
            try db.execute("DELETE FROM chunks WHERE rowid IN (SELECT p.id FROM passages p LEFT JOIN search_state s ON s.revision_id=p.revision_id AND s.generation=p.generation AND s.state='ready' WHERE s.revision_id IS NULL)")
            try db.execute("DELETE FROM passages WHERE NOT EXISTS(SELECT 1 FROM search_state s WHERE s.revision_id=passages.revision_id AND s.generation=passages.generation AND s.state='ready')")
            try db.execute("DELETE FROM search_state WHERE state<>'ready'")
            try db.execute("UPDATE revisions SET search_ready=0 WHERE id NOT IN (SELECT revision_id FROM search_state WHERE state='ready')")
        }
        do {
            guard try db.scalar("""
                WITH p AS MATERIALIZED (SELECT revision_id,generation,count(*) AS count FROM passages GROUP BY revision_id,generation),
                     c AS MATERIALIZED (SELECT revision_id,generation,count(*) AS count FROM chunks GROUP BY revision_id,generation)
                SELECT 1 FROM search_state s LEFT JOIN p ON p.revision_id=s.revision_id AND p.generation=s.generation
                  LEFT JOIN c ON c.revision_id=s.revision_id AND c.generation=s.generation
                WHERE s.state='ready' AND (s.passage_count<>coalesce(p.count,0) OR s.passage_count<>coalesce(c.count,0)) LIMIT 1
                """) == nil else { throw ReferenceStoreError.unavailable }
            try db.execute("INSERT INTO chunks(chunks) VALUES('integrity-check')")
        }
        catch {
            // Search is derived; authoritative text and durable pins must survive its repair.
            try db.transaction {
                try db.execute("DROP TABLE chunks")
                try db.execute("CREATE VIRTUAL TABLE chunks USING fts5(revision_id UNINDEXED,generation UNINDEXED,text,tokenize='ascii')")
                try db.execute("DELETE FROM passages"); try db.execute("DELETE FROM search_state")
                try db.execute("UPDATE revisions SET search_ready=0")
            }
        }
    }

    static func write(databasePath: String, home: URL, revision: String, generation: String, markdown: Bool, budget: ReferenceStorageBudget) async throws {
        let text = try ReferenceRevisionPage.fullText(databasePath: databasePath, revision: revision)
        let db = try ReferenceDatabase(path: databasePath)
        while let row = try db.rows("SELECT id FROM passages WHERE revision_id=? AND generation<>? LIMIT 64", [revision, generation]).first,
              row[0] != nil {
            try Task.checkCancellation()
            try db.transaction {
                try requireGeneration(db, revision: revision, generation: generation)
                try db.execute("DELETE FROM chunks WHERE rowid IN (SELECT id FROM passages WHERE revision_id=? AND generation<>? LIMIT 64)", [revision, generation])
                try db.execute("DELETE FROM passages WHERE id IN (SELECT id FROM passages WHERE revision_id=? AND generation<>? LIMIT 64)", [revision, generation])
            }
        }
        let passages = PrepMaterialChunker.passages(text: text, markdown: markdown)
        for (ordinal, passage) in passages.enumerated() {
            try Task.checkCancellation()
            let original = String(text[passage.range])
            let tokens = ReferenceSearchTokenizer.indexedText(original)
            try budget.write(home: home, bytes: tokens.utf8.count + original.utf8.count) {
                try db.transaction {
                    try requireGeneration(db, revision: revision, generation: generation)
                    try db.execute("INSERT INTO passages(revision_id,generation,ordinal,offset,end_offset,section,text) VALUES(?,?,?,?,?,?,?)", [revision, generation, String(ordinal), String(passage.offset), String(passage.offset + original.unicodeScalars.count), passage.section, original])
                    let rowID = try db.scalar("SELECT last_insert_rowid()")
                    try db.execute("INSERT INTO chunks(rowid,revision_id,generation,text) VALUES(?,?,?,?)", [rowID, revision, generation, tokens])
                }
            }
            await barrier(home: home, name: "index-after-batch")
        }
        await barrier(home: home, name: "index-before-publish")
        try Task.checkCancellation()
        try db.transaction {
            try requireGeneration(db, revision: revision, generation: generation)
            guard try db.scalar("SELECT count(*) FROM passages WHERE revision_id=? AND generation=?", [revision, generation]) == String(passages.count) else { throw ReferenceStoreError.unavailable }
            try db.execute("UPDATE search_state SET state='ready',passage_count=? WHERE revision_id=? AND generation=?", [String(passages.count), revision, generation])
            try db.execute("UPDATE revisions SET search_ready=1 WHERE id=? AND ready=1", [revision])
        }
    }

    static func requireGeneration(_ db: ReferenceDatabase, revision: String, generation: String) throws {
        guard try db.scalar("SELECT 1 FROM search_state s JOIN revisions r ON r.id=s.revision_id AND r.ready=1 WHERE s.revision_id=? AND s.generation=? AND s.version=? AND s.state='preparing'", [revision, generation, version]) != nil else { throw ReferenceStoreError.superseded }
    }

    static func barrier(home: URL, name: String) async {
        #if JARVIS_LIVE_E2E
        let gate = home.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: gate.path) else { return }
        try? Data().write(to: home.appendingPathComponent(name + "-arrived"))
        while FileManager.default.fileExists(atPath: gate.path), !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
        #endif
    }
}
