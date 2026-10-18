import Foundation
import JarvisCore

extension ReferenceDocumentStore {
    func configure(_ payload: Payload) throws -> Data {
        guard let generation = payload.generation, generation >= 0, let enabled = payload.enabled,
              let sources = payload.sources, let app = instance else { throw ReferenceStoreError.unavailable }
        guard sources.count <= ReferenceDiscovery.maximumSources else { throw ReferenceStoreError.resource_limit }
        let sorted = sources.sorted { $0.source_id.uuidString < $1.source_id.uuidString }
        guard Set(sources.map(\.source_id)).count == sources.count else { throw ReferenceStoreError.unavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceJSON = String(decoding: try encoder.encode(sorted), as: UTF8.self)
        if let row = try db.rows("SELECT generation,enabled,state,sources FROM configuration WHERE id=1").first,
           let current = Int(row[0] ?? "") {
            if generation < current { return try json(["generation": current, "state": "superseded", "total_count": 0]) }
            if generation == current {
                guard row[1] == (enabled ? "1" : "0"), row[3] == sourceJSON else { throw ReferenceStoreError.superseded }
                if row[2] == "ready" || row[2] == "disabled" || row[2] == "preparing" { return try metadataStatus(generation) }
            }
        }
        configurationTask?.cancel(); backgroundTask?.cancel()
        for id in Array(jobs.keys) {
            jobs[id]?.background = false
            cancelUnneeded(id)
        }
        let token = UUID(); configurationToken = token
        try db.execute("INSERT INTO configuration VALUES(1,?,?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET app=excluded.app,generation=excluded.generation,enabled=excluded.enabled,state=excluded.state,error=excluded.error,total_count=0,sources=excluded.sources",
                       [app.uuidString.lowercased(), String(generation), enabled ? "1" : "0", enabled ? "preparing" : "disabled", nil, sourceJSON])
        if enabled {
            let home = home
            configurationTask = Task(priority: .utility) {
                do {
                    let discovery = Task.detached(priority: .utility) {
                        #if JARVIS_LIVE_E2E
                        if let value = try? String(contentsOf: home.appendingPathComponent("metadata-delay-ms"), encoding: .utf8),
                           let delay = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), (0...5000).contains(delay) {
                            try await Task.sleep(for: .milliseconds(delay))
                        }
                        #endif
                        return try ReferenceDiscovery.scan(sorted)
                    }
                    let discovered = try await withTaskCancellationHandler { try await discovery.value }
                        onCancel: { discovery.cancel() }
                    try await publishMetadata(discovered, generation: generation, token: token)
                } catch {
                    guard configurationToken == token, !closed else { return }
                    let reason = (error as? ReferenceStoreError)?.rawValue ?? "unavailable"
                    try? db.execute("UPDATE configuration SET state='failed',error=? WHERE id=1 AND generation=?", [reason, String(generation)])
                }
            }
        }
        return try metadataStatus(generation)
    }

    func metadataStatus(_ requested: Int?) throws -> Data {
        guard let row = try db.rows("SELECT generation,state,total_count,error FROM configuration WHERE id=1").first,
              let generation = Int(row[0] ?? "") else { throw ReferenceStoreError.unavailable }
        if let requested, requested != generation {
            return try json(["generation": generation, "state": "superseded", "total_count": 0])
        }
        var result: [String: Any] = ["generation": generation, "state": row[1] ?? "failed", "total_count": Int(row[2] ?? "0") ?? 0]
        if let error = row[3] { result["error"] = error }
        return try json(result)
    }

    private func publishMetadata(_ discovered: [ReferenceDiscovery.Document], generation: Int, token: UUID) async throws {
        guard configurationToken == token, !closed else { throw ReferenceStoreError.superseded }
        let previous = try db.rows("SELECT id,path,identity,present FROM documents ORDER BY present DESC,rowid DESC")
        var paths: [String: [String?]] = [:]
        var identities: [String: [[String?]]] = [:]
        for row in previous {
            if let path = row[1], paths[path] == nil { paths[path] = row }
            if row[3] == "1", let identity = row[2] { identities[identity, default: []].append(row) }
        }
        let currentPaths = Set(discovered.map(\.path))
        var used = Set<String>()
        let duplicates = Dictionary(grouping: discovered, by: \.name)
        try db.transaction {
            try db.execute("DELETE FROM metadata WHERE generation=?", [String(generation)])
            try db.execute("DELETE FROM source_members WHERE generation=?", [String(generation)])
        }
        for begin in stride(from: 0, to: discovered.count, by: 100) {
            guard configurationToken == token, !closed else { throw ReferenceStoreError.superseded }
            try db.transaction {
                for item in discovered[begin..<min(begin + 100, discovered.count)] {
                    var identifier: String?
                    if let old = paths[item.path], old[3] == "1" { identifier = old[0] }
                    if identifier == nil, let candidates = identities[item.identity], candidates.count == 1,
                       let oldPath = candidates[0][1], !currentPaths.contains(oldPath) { identifier = candidates[0][0] }
                    if identifier.map({ used.contains($0) }) == true { identifier = nil }
                    let id = identifier ?? UUID().uuidString.lowercased()
                    used.insert(id)
                    let name = duplicates[item.name, default: []].count > 1 ? "\(item.name) [\(id.prefix(8))]" : item.name
                    try db.execute("INSERT INTO metadata VALUES(?,?,?,?,?,?,?)", [String(generation), id, name, item.format, item.path, item.root, item.identity])
                    for source in item.sourceIDs {
                        try db.execute("INSERT INTO source_members VALUES(?,?,?)", [String(generation), source.uuidString.lowercased(), id])
                    }
                }
            }
            await Task.yield()
        }
        guard configurationToken == token, !closed else { throw ReferenceStoreError.superseded }
        try db.transaction {
            try db.execute("UPDATE documents SET present=0")
            try db.execute("INSERT INTO documents(id,path,identity,present) SELECT document_id,path,identity,1 FROM metadata WHERE generation=? ON CONFLICT(id) DO UPDATE SET path=excluded.path,identity=excluded.identity,present=1", [String(generation)])
            try db.execute("UPDATE configuration SET state='ready',error=NULL,total_count=? WHERE id=1 AND generation=?", [String(discovered.count), String(generation)])
        }
        try db.execute("DELETE FROM metadata WHERE generation<>?", [String(generation)])
        try db.execute("DELETE FROM source_members WHERE generation<>?", [String(generation)])
        let ids = Array(used).sorted()
        backgroundTask = Task(priority: .background) {
            for id in ids {
                guard !Task.isCancelled, configurationToken == token, !closed else { return }
                do { _ = try await prepare(document: id, session: nil, waiter: UUID(), background: true) }
                catch { if Task.isCancelled { return } }
            }
        }
    }

    func admit(_ request: ReferenceHelperRequest, _ payload: Payload) throws -> Data {
        guard let session = request.session?.uuidString.lowercased(), let start = payload.start_id?.uuidString.lowercased(),
              let app = instance?.uuidString.lowercased(), let generation = payload.generation else { throw ReferenceStoreError.unavailable }
        if try db.scalar("SELECT 1 FROM abandoned WHERE app=? AND start_id=?", [app, start]) != nil {
            return try json(["state": "released"])
        }
        if let previous = try db.rows("SELECT state,catalog,start_id,generation FROM sessions WHERE id=? AND app=?", [session, app]).first {
            guard previous[0] == "active", previous[2] == start else { return try json(["state": "released"]) }
            guard previous[3] == String(generation), let catalog = previous[1], let data = catalog.data(using: .utf8) else { return try json(["state": "superseded"]) }
            return try json(["state": "ready", "catalog": JSONSerialization.jsonObject(with: data)])
        }
        guard let state = try db.rows("SELECT generation,state,total_count FROM configuration WHERE id=1").first else { return try json(["state": "preparing"]) }
        guard state[0] == String(generation) else { return try json(["state": "superseded"]) }
        guard state[1] == "ready" else { return try json(["state": state[1] ?? "failed"]) }
        guard state[2] != "0" else { return try json(["state": "empty"]) }
        let entries = try db.rows("SELECT document_id,name,format FROM metadata WHERE generation=? ORDER BY document_id LIMIT 200", [String(generation)]).map { row -> DocumentCatalog.Entry in
            guard let id = row[0].flatMap(UUID.init(uuidString:)), let name = row[1], let format = row[2] else { throw ReferenceStoreError.unavailable }
            return .init(documentID: id, name: name, format: format)
        }
        let catalog = try DocumentCatalog.bounded(entries, totalCount: Int(state[2] ?? "0") ?? 0).serialized()
        try db.transaction {
            try db.execute("INSERT INTO sessions VALUES(?,?,?,?, 'active',?)", [session, app, start, String(generation), String(decoding: catalog, as: UTF8.self)])
            try db.execute("INSERT INTO session_documents SELECT ?,document_id,name,format,path,root,identity,NULL FROM metadata WHERE generation=?", [session, String(generation)])
        }
        return try json(["state": "ready", "catalog": JSONSerialization.jsonObject(with: catalog)])
    }

    func list(_ request: ReferenceHelperRequest, _ payload: Payload) throws -> Data {
        let session = try requireSession(request, payload)
        let cursor = payload.cursor ?? 0
        guard cursor >= 0 else { throw ReferenceStoreError.invalid_cursor }
        let query = payload.query ?? ""
        guard query.unicodeScalars.count <= 512 else { throw ReferenceStoreError.limit_exceeded }
        let count = Int(try db.scalar("SELECT count(*) FROM session_documents WHERE session_id=? AND instr(reference_casefold(name),reference_casefold(?))>0", [session, query]) ?? "0") ?? 0
        guard cursor <= count else { throw ReferenceStoreError.invalid_cursor }
        let rows = try db.rows("SELECT document_id,name,format FROM session_documents WHERE session_id=? AND instr(reference_casefold(name),reference_casefold(?))>0 ORDER BY name,document_id LIMIT 100 OFFSET ?", [session, query, String(cursor)])
        let entries = rows.map { ["document_id": $0[0] ?? "", "name": $0[1] ?? "", "format": $0[2] ?? ""] }
        return try json(["status": "ok", "entries": entries, "total_count": count,
                         "next_cursor": cursor + rows.count < count ? cursor + rows.count : NSNull()])
    }
}
