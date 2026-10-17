import Foundation
import CryptoKit
import JarvisCore
import SQLite3

actor ReferenceDocumentStore {
    struct Payload: Decodable {
        let app_instance_id: UUID?
        let generation: Int?
        let enabled: Bool?
        let sources: [ReferenceDiscovery.Source]?
        let start_id: UUID?
        let document_id: UUID?
        let document_ids: [UUID]?
        let offset: Int?
        let cursor: Int?
        let query: String?
        let revision_id: String?
        let owned_session_ids: [UUID]?
    }
    struct Preparation {
        let token: UUID
        let task: Task<Void, Never>
        var background: Bool
        var waiters: [UUID: CheckedContinuation<String, Error>]
        let sourceState: String
    }
    let db: ReferenceDatabase
    let home: URL
    let databasePath: String
    let staging: URL
    let converters: ReferenceConversionPool
    private let lock: Int32
    var instance: UUID?
    var configurationTask: Task<Void, Never>?
    var configurationToken = UUID()
    var backgroundTask: Task<Void, Never>?
    var indexTask: Task<Void, Never>?
    var pendingIndexes: Set<String> = []
    var jobs: [String: Preparation] = [:]
    var reservations: Set<UUID> = []
    var closed = false
    var waiterSessions: [UUID: String] = [:]
    var waiterTimers: [UUID: Task<Void, Never>] = [:]
    var revisionCaptures: [String: (CapturedReference, URL, URL)] = [:]
    var peakDiskBytes: Int64 = 0
    var pageReaders = 0
    static let reservationBytes: Int64 = 450 * 1024 * 1024
    static let cacheTarget: Int64 = 1024 * 1024 * 1024

    init(home: URL) throws {
        let files = FileManager.default
        var homeInfo = stat()
        if lstat(home.path, &homeInfo) == 0, homeInfo.st_mode & S_IFMT != S_IFDIR { throw ReferenceStoreError.unavailable }
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        try files.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        lock = open(home.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ReferenceStoreError.unavailable }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); throw ReferenceStoreError.unavailable
        }
        do {
            self.home = home
            staging = home.appendingPathComponent("staging", isDirectory: true)
            var stagingInfo = stat()
            if lstat(staging.path, &stagingInfo) == 0, stagingInfo.st_mode & S_IFMT != S_IFDIR { throw ReferenceStoreError.unavailable }
            try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            for item in try files.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) { try files.removeItem(at: item) }
            databasePath = home.appendingPathComponent("documents.sqlite").path
            for suffix in ["", "-wal", "-shm"] {
                let path = databasePath + suffix
                var attributes = stat()
                if lstat(path, &attributes) == 0, attributes.st_mode & S_IFMT != S_IFREG { throw ReferenceStoreError.unavailable }
            }
            let file = open(databasePath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard file >= 0 else { throw ReferenceStoreError.unavailable }
            guard fchmod(file, 0o600) == 0 else { Darwin.close(file); throw ReferenceStoreError.unavailable }
            Darwin.close(file)
            db = try ReferenceDatabase(path: databasePath)
            try db.script("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                PRAGMA temp_store=MEMORY;
                PRAGMA auto_vacuum=INCREMENTAL;
                PRAGMA wal_autocheckpoint=256;
                CREATE TABLE IF NOT EXISTS owner(id INTEGER PRIMARY KEY CHECK(id=1),app TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS configuration(id INTEGER PRIMARY KEY CHECK(id=1),app TEXT,generation INTEGER,enabled INTEGER,state TEXT,error TEXT,total_count INTEGER,sources TEXT);
                CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,path TEXT NOT NULL,identity TEXT NOT NULL,present INTEGER NOT NULL,current_revision TEXT);
                CREATE INDEX IF NOT EXISTS documents_path ON documents(path);
                CREATE INDEX IF NOT EXISTS documents_identity ON documents(identity);
                CREATE INDEX IF NOT EXISTS documents_revision ON documents(current_revision);
                CREATE TABLE IF NOT EXISTS metadata(generation INTEGER,document_id TEXT,name TEXT,format TEXT,path TEXT,root TEXT,identity TEXT,PRIMARY KEY(generation,document_id));
                CREATE INDEX IF NOT EXISTS metadata_document ON metadata(document_id);
                CREATE TABLE IF NOT EXISTS source_members(generation INTEGER,source_id TEXT,document_id TEXT,PRIMARY KEY(generation,source_id,document_id));
                CREATE TABLE IF NOT EXISTS revisions(id TEXT PRIMARY KEY,document_id TEXT NOT NULL,source_hash TEXT NOT NULL,processor TEXT NOT NULL,scalar_count INTEGER NOT NULL,text_hash TEXT NOT NULL,ready INTEGER NOT NULL,search_ready INTEGER NOT NULL DEFAULT 0,last_used INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS content_parts(revision_id TEXT NOT NULL,part INTEGER NOT NULL,bytes BLOB NOT NULL,PRIMARY KEY(revision_id,part));
                CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,app TEXT NOT NULL,start_id TEXT NOT NULL,generation INTEGER,state TEXT NOT NULL,catalog TEXT);
                CREATE TABLE IF NOT EXISTS session_documents(session_id TEXT,document_id TEXT,name TEXT,format TEXT,path TEXT,root TEXT,identity TEXT,pin TEXT,PRIMARY KEY(session_id,document_id));
                CREATE INDEX IF NOT EXISTS session_pins ON session_documents(pin);
                CREATE TABLE IF NOT EXISTS abandoned(app TEXT,start_id TEXT,PRIMARY KEY(app,start_id));
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(revision_id UNINDEXED,text,tokenize='unicode61 remove_diacritics 0');
                DELETE FROM revisions WHERE ready=0;
                DELETE FROM content_parts WHERE revision_id NOT IN (SELECT id FROM revisions);
                UPDATE configuration SET state='failed',error='preparing' WHERE state='preparing';
                """)
            try ReferenceSearchIndex.initialize(db)
            converters = ReferenceConversionPool(staging: staging)
        } catch { Darwin.close(lock); throw error }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        configurationTask?.cancel(); backgroundTask?.cancel(); indexTask?.cancel()
        let running = Array(jobs.values)
        for job in running {
            job.task.cancel()
            for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        jobs.removeAll()
        for timer in waiterTimers.values { timer.cancel() }
        waiterTimers.removeAll(); waiterSessions.removeAll()
        await converters.close()
        await indexTask?.value
        for job in running { await job.task.value }
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        Darwin.close(lock)
    }

    func execute(_ request: ReferenceHelperRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            guard !closed else { throw ReferenceStoreError.unavailable }
            let payload = try JSONDecoder().decode(Payload.self, from: request.payload)
            guard let app = payload.app_instance_id else { throw ReferenceStoreError.unknown_session }
            try bindInstance(app)
            switch request.operation {
            case "configure": return try configure(payload)
            case "metadata": return try metadataStatus(payload.generation)
            case "admit": return try admit(request, payload)
            case "list": return try list(request, payload)
            case "read": return try await read(request, payload)
            case "search": return try await search(request, payload)
            case "release": return try release(request, payload)
            case "abandon": return try abandon(payload)
            case "reconcile": return try reconcile(payload)
            case "diagnostics": return try json(["status": "ok", "disk_bytes": diskBytes(), "reserved_bytes": Int64(reservations.count) * Self.reservationBytes, "peak_disk_bytes": peakDiskBytes])
            default: throw ReferenceStoreError.unavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ReferenceStoreError { return try json(["status": error.rawValue]) }
        catch let error as ReferenceConversionError { return try json(["status": error.rawValue]) }
        catch { return try json(["status": "unavailable"]) }
    }

    func bindInstance(_ app: UUID) throws {
        if let instance { guard instance == app else { throw ReferenceStoreError.unknown_session }; return }
        let identifier = app.uuidString.lowercased()
        try db.transaction {
            try db.execute("UPDATE sessions SET state='ended' WHERE app<>?", [identifier])
            try db.execute("DELETE FROM session_documents WHERE session_id IN (SELECT id FROM sessions WHERE state='ended')")
            if try db.scalar("SELECT app FROM owner WHERE id=1") != identifier {
                try db.execute("DELETE FROM metadata"); try db.execute("DELETE FROM source_members"); try db.execute("DELETE FROM configuration")
            }
            try db.execute("INSERT INTO owner VALUES(1,?) ON CONFLICT(id) DO UPDATE SET app=excluded.app", [identifier])
        }
        instance = app
        try cleanup()
        try resumeIndexes()
    }

    func requireSession(_ request: ReferenceHelperRequest, _ payload: Payload) throws -> String {
        guard let session = request.session?.uuidString.lowercased(), let app = payload.app_instance_id?.uuidString.lowercased(),
              try db.scalar("SELECT state FROM sessions WHERE id=? AND app=?", [session, app]) == "active" else {
            throw ReferenceStoreError.unknown_session
        }
        return session
    }
    #if JARVIS_LIVE_E2E
    func replyDelay(for operation: String) -> Int {
        guard operation == "admit" || operation == "search",
              let value = try? String(contentsOf: home.appendingPathComponent("\(operation)-reply-delay-ms"), encoding: .utf8),
              let delay = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), (0...5000).contains(delay) else { return 0 }
        return delay
    }
    #endif
    func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
