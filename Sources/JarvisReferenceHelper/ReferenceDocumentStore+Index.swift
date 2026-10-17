import Foundation

extension ReferenceDocumentStore {
    func enqueueIndex(_ revision: String) throws {
        guard !closed,
              try db.scalar("SELECT ready FROM revisions WHERE id=?", [revision]) == "1",
              try db.scalar("SELECT state FROM search_state WHERE revision_id=? AND version=?", [revision, ReferenceSearchIndex.version]) != "ready" else { return }
        pendingIndexes.insert(revision)
        startNextIndex()
    }

    func startNextIndex() {
        guard indexTask == nil, !closed else { return }
        while let revision = pendingIndexes.first {
            pendingIndexes.remove(revision)
            let generation = UUID().uuidString.lowercased()
            do {
                guard try db.scalar("SELECT ready FROM revisions WHERE id=? AND search_ready=0", [revision]) == "1" else { continue }
                try db.transaction {
                    try db.execute("UPDATE revisions SET search_ready=0 WHERE id=?", [revision])
                    try db.execute("INSERT INTO search_state(revision_id,generation,version,state) VALUES(?,?,?,'preparing') ON CONFLICT(revision_id) DO UPDATE SET generation=excluded.generation,version=excluded.version,state='preparing'", [revision, generation, ReferenceSearchIndex.version])
                }
                let markdown = try db.scalar("SELECT 1 FROM session_documents WHERE pin=? AND format='md' UNION ALL SELECT 1 FROM metadata m JOIN documents d ON d.id=m.document_id WHERE d.current_revision=? AND m.format='md' LIMIT 1", [revision, revision]) != nil
                let path = databasePath, directory = home
                let task = Task.detached(priority: .utility) {
                    try await ReferenceSearchIndex.write(databasePath: path, home: directory, revision: revision, generation: generation, markdown: markdown)
                }
                indexTask = Task {
                    do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
                    catch {
                        let reason = (error as? ReferenceStoreError)?.rawValue ?? "failed"
                        try? db.execute("UPDATE search_state SET state=? WHERE revision_id=? AND generation=? AND state='preparing'", [reason, revision, generation])
                    }
                    indexTask = nil
                    if !closed { startNextIndex() }
                }
                return
            } catch {
                try? db.execute("UPDATE search_state SET state='failed' WHERE revision_id=? AND generation=?", [revision, generation])
            }
        }
    }

    func resumeIndexes() throws {
        for row in try db.rows("SELECT id FROM revisions WHERE ready=1 AND search_ready=0") {
            if let revision = row[0] { try enqueueIndex(revision) }
        }
    }
}
