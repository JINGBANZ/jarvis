import Foundation
import SQLite3

actor ReferenceDocumentStore {
    private enum Failure: Error { case unavailable }
    private struct Source { let url: URL; let root: URL }
    private struct Payload: Decodable {
        struct Document: Decodable { let document_id: UUID; let name: String }
        let root: String?
        let documents: [Document]?
        let document_id: UUID?
        let offset: Int?
        let query: String?
    }
    private var database: OpaquePointer?
    private let lock: Int32
    private var sources: [UUID: Source] = [:]
    private var session: UUID?
    private static let maximumSource = 1_048_576
    private static let maximumPage = 16_000

    init(home: URL) throws {
        let files = FileManager.default
        guard home.resolvingSymlinksInPath().pathComponents == home.standardizedFileURL.pathComponents else { throw Failure.unavailable }
        try files.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        lock = open(home.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure.unavailable }
        guard fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            throw Failure.unavailable
        }
        do {
            let staging = home.appendingPathComponent("staging")
            guard staging.resolvingSymlinksInPath().pathComponents == staging.standardizedFileURL.pathComponents else { throw Failure.unavailable }
            try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            let path = home.appendingPathComponent("control.sqlite").path
            let file = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard file >= 0 else { throw Failure.unavailable }
            var info = stat()
            let valid = fstat(file, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && fchmod(file, 0o600) == 0
            Darwin.close(file)
            guard valid else { throw Failure.unavailable }
            var opened: OpaquePointer?
            let code = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            guard code == SQLITE_OK else {
                sqlite3_close(opened)
                throw Failure.unavailable
            }
            database = opened
            // DELETE journals stay in the private store; temp work stays in memory.
            let sql = """
                PRAGMA journal_mode=DELETE;
                PRAGMA synchronous=FULL;
                PRAGMA temp_store=MEMORY;
                CREATE TABLE IF NOT EXISTS store_version(version INTEGER NOT NULL);
                INSERT INTO store_version SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM store_version);
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(document_id UNINDEXED, text, tokenize='unicode61 remove_diacritics 0');
                """
            guard sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(opened)
                database = nil
                throw Failure.unavailable
            }
        } catch {
            Darwin.close(lock)
            throw error
        }
    }

    func close() {
        guard let database else { return }
        sqlite3_close(database)
        self.database = nil
        Darwin.close(lock)
    }

    func execute(_ request: ReferenceHelperRequest) throws -> Data {
        try Task.checkCancellation()
        let payload = try JSONDecoder().decode(Payload.self, from: request.payload)
        if request.operation == "configure" {
            guard let path = payload.root, let documents = payload.documents, documents.count <= 100,
                  let session = request.session else { throw Failure.unavailable }
            let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                throw Failure.unavailable
            }
            var configured: [UUID: Source] = [:]
            for document in documents {
                let url = root.appendingPathComponent(document.name)
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard within(resolved, root), ["txt", "md"].contains(resolved.pathExtension.lowercased()),
                      FileManager.default.fileExists(atPath: resolved.path) else { throw Failure.unavailable }
                configured[document.document_id] = Source(url: url, root: root)
            }
            sources = configured
            self.session = session
            return try json(["documents": sources.count])
        }
        guard session != nil, session == request.session else { throw Failure.unavailable }
        switch request.operation {
        case "release":
            sources.removeAll(); session = nil
            return Data("{}".utf8)
        case "read":
            guard let id = payload.document_id else { throw Failure.unavailable }
            let scalars = try read(id).unicodeScalars
            let offset = payload.offset ?? 0
            guard offset >= 0, offset <= scalars.count else { throw Failure.unavailable }
            let text = String(String.UnicodeScalarView(scalars.dropFirst(offset).prefix(Self.maximumPage)))
            return try json(["text": text, "next_offset": min(scalars.count, offset + Self.maximumPage), "total_scalars": scalars.count])
        case "search":
            guard let query = payload.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.unicodeScalars.count <= 512 else { throw Failure.unavailable }
            return try search(query)
        default: throw Failure.unavailable
        }
    }

    private func within(_ url: URL, _ root: URL) -> Bool {
        url.pathComponents.starts(with: root.pathComponents) && url.pathComponents.count > root.pathComponents.count
    }

    private func read(_ id: UUID) throws -> String {
        guard let source = sources[id] else { throw Failure.unavailable }
        let resolved = source.url.resolvingSymlinksInPath().standardizedFileURL
        guard within(resolved, source.root) else { throw Failure.unavailable }
        let descriptor = open(resolved.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
        var raw = Data()
        while raw.count <= Self.maximumSource {
            try Task.checkCancellation()
            let piece = try handle.read(upToCount: min(65_536, Self.maximumSource + 1 - raw.count)) ?? Data()
            if piece.isEmpty { break }
            raw.append(piece)
        }
        guard raw.count <= Self.maximumSource, fstat(descriptor, &after) == 0,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let text = String(data: raw, encoding: .utf8) else { throw Failure.unavailable }
        return text
    }

    private func search(_ query: String) throws -> Data {
        try sql("BEGIN")
        do {
            try sql("DELETE FROM chunks")
            for (id, _) in sources.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try Task.checkCancellation()
                let text = String(String.UnicodeScalarView(try read(id).unicodeScalars.prefix(Self.maximumPage)))
                let insert = try prepare("INSERT INTO chunks(document_id,text) VALUES(?,?)")
                defer { sqlite3_finalize(insert) }
                try bind(id.uuidString.lowercased(), to: insert, at: 1)
                try bind(text, to: insert, at: 2)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.unavailable }
            }
            try sql("COMMIT")
        } catch {
            try sql("ROLLBACK")
            throw error
        }
        // Quote the literal input; phase 1 does not expose the FTS query language.
        let literal = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let statement = try prepare("SELECT document_id,text FROM chunks WHERE chunks MATCH ? ORDER BY rank LIMIT 3")
        defer { sqlite3_finalize(statement) }
        try bind(literal, to: statement, at: 1)
        var hits: [[String: String]] = []
        while true {
            try Task.checkCancellation()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let id = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else {
                throw Failure.unavailable
            }
            let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, 1)))
            let excerpt = String(String.UnicodeScalarView(String(decoding: bytes, as: UTF8.self).unicodeScalars.prefix(2000)))
            hits.append(["document_id": String(cString: id), "text": excerpt])
        }
        return try json(["hits": hits])
    }

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func sql(_ text: String) throws {
        guard sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    }
    private func prepare(_ text: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, text, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.unavailable }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), transient) == SQLITE_OK else { throw Failure.unavailable }
    }
}
