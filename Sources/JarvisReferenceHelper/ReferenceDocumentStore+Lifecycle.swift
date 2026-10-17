import Foundation

extension ReferenceDocumentStore {
    func release(_ request: ReferenceHelperRequest, _ payload: Payload) throws -> Data {
        guard let session = request.session?.uuidString.lowercased(), let app = instance?.uuidString.lowercased() else { throw ReferenceStoreError.unknown_session }
        if let owner = try db.scalar("SELECT app FROM sessions WHERE id=?", [session]), owner != app { throw ReferenceStoreError.unknown_session }
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO sessions VALUES(?,?,?,NULL,'ended',NULL)", [session, app, payload.start_id?.uuidString.lowercased() ?? session])
            try db.execute("UPDATE sessions SET state='ended' WHERE id=? AND app=?", [session, app])
            try db.execute("DELETE FROM session_documents WHERE session_id=?", [session])
        }
        detachSession(session)
        try cleanup()
        return try json(["status": "ok"])
    }
    func abandon(_ payload: Payload) throws -> Data {
        guard let start = payload.start_id?.uuidString.lowercased(), let app = instance?.uuidString.lowercased() else { throw ReferenceStoreError.unknown_session }
        let sessions = try db.rows("SELECT id FROM sessions WHERE app=? AND start_id=?", [app, start]).compactMap { $0[0] }
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO abandoned VALUES(?,?)", [app, start])
            try db.execute("UPDATE sessions SET state='ended' WHERE app=? AND start_id=?", [app, start])
            try db.execute("DELETE FROM session_documents WHERE session_id IN (SELECT id FROM sessions WHERE app=? AND start_id=?)", [app, start])
        }
        for session in sessions { detachSession(session) }
        try cleanup()
        return try json(["status": "ok"])
    }
    func reconcile(_ payload: Payload) throws -> Data {
        guard let owned = payload.owned_session_ids, let app = instance?.uuidString.lowercased() else { throw ReferenceStoreError.unknown_session }
        let identifiers = Set(owned.map { $0.uuidString.lowercased() })
        let abandoned = try db.rows("SELECT id FROM sessions WHERE app=? AND state='active'", [app]).compactMap { $0[0] }.filter { !identifiers.contains($0) }
        try db.transaction {
            for session in abandoned {
                try db.execute("UPDATE sessions SET state='ended' WHERE id=?", [session])
                try db.execute("DELETE FROM session_documents WHERE session_id=?", [session])
            }
        }
        for session in abandoned { detachSession(session) }
        try cleanup()
        return try json(["status": "ok", "released_count": abandoned.count])
    }
    func detachSession(_ session: String) {
        for (waiter, owner) in Array(waiterSessions) where owner == session {
            detachWaiter(waiter, error: ReferenceStoreError.unknown_session)
        }
        for document in Array(jobs.keys) { cancelUnneeded(document) }
    }
    func diskBytes() -> Int64 {
        guard let files = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return Self.cacheTarget }
        var bytes: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]), values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
        }
        peakDiskBytes = max(peakDiskBytes, bytes)
        return bytes
    }
    func cleanup(pressure: Bool = false) throws {
        try db.transaction {
            try db.execute("UPDATE documents SET current_revision=NULL WHERE present=0 AND id NOT IN (SELECT document_id FROM session_documents)")
            try db.execute("DELETE FROM revisions WHERE ready=1 AND id NOT IN (SELECT pin FROM session_documents WHERE pin IS NOT NULL) AND id NOT IN (SELECT current_revision FROM documents WHERE current_revision IS NOT NULL)")
            if pressure {
                try db.execute("UPDATE documents SET current_revision=NULL WHERE current_revision NOT IN (SELECT pin FROM session_documents WHERE pin IS NOT NULL)")
                try db.execute("DELETE FROM revisions WHERE ready=1 AND id NOT IN (SELECT pin FROM session_documents WHERE pin IS NOT NULL)")
            }
            try db.execute("DELETE FROM content_parts WHERE revision_id NOT IN (SELECT id FROM revisions)")
            try db.execute("DELETE FROM chunks WHERE revision_id NOT IN (SELECT id FROM revisions)")
            try db.execute("DELETE FROM passages WHERE revision_id NOT IN (SELECT id FROM revisions) OR NOT EXISTS(SELECT 1 FROM search_state s WHERE s.revision_id=passages.revision_id AND s.generation=passages.generation)")
            try db.execute("DELETE FROM chunks WHERE rowid NOT IN (SELECT id FROM passages)")
            try db.execute("DELETE FROM search_state WHERE revision_id NOT IN (SELECT id FROM revisions)")
            try db.execute("DELETE FROM revision_sources WHERE revision_id NOT IN (SELECT id FROM revisions)")
        }
        let retained = Set(try db.rows("SELECT id FROM revisions").compactMap { $0[0] })
        revisionCaptures = revisionCaptures.filter { retained.contains($0.key) }
        try db.execute("PRAGMA wal_checkpoint(PASSIVE)")
        try db.execute("PRAGMA incremental_vacuum(256)")
    }
    func reserve(_ token: UUID) throws {
        guard reservations.count < 2 else { throw ReferenceStoreError.preparing }
        let required = Int64(reservations.count + 1) * Self.reservationBytes
        if diskBytes() + required > Self.cacheTarget { try cleanup(pressure: true) }
        guard diskBytes() + required <= Self.cacheTarget else { throw ReferenceStoreError.cache_full }
        var volume = statfs()
        guard statfs(home.path, &volume) == 0 else { throw ReferenceStoreError.disk_full }
        guard UInt64(volume.f_bavail) * UInt64(volume.f_bsize) >= UInt64(required) else { throw ReferenceStoreError.disk_full }
        reservations.insert(token)
    }
}
