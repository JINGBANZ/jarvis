import Foundation
import SQLite3

final class ReferenceDatabase {
    enum Failure: Error { case unavailable }
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(handle); handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 250)
    }
    deinit { sqlite3_close(handle) }

    func failure() -> Error {
        sqlite3_extended_errcode(handle) & 0xff == SQLITE_FULL ? ReferenceStoreError.disk_full : Failure.unavailable
    }

    func statement(_ sql: String, _ values: [String?] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        do {
            for (offset, value) in values.enumerated() {
                let code: Int32
                if let value {
                    code = sqlite3_bind_text(result, Int32(offset + 1), value, Int32(value.utf8.count),
                                             unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else { code = sqlite3_bind_null(result, Int32(offset + 1)) }
                guard code == SQLITE_OK else { throw failure() }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }
    func execute(_ sql: String, _ values: [String?] = []) throws {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        var code = sqlite3_step(query)
        while code == SQLITE_ROW { code = sqlite3_step(query) }
        guard code == SQLITE_DONE else { throw failure() }
    }
    func script(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        var rows: [[String?]] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(query)).map { index in
                guard let bytes = sqlite3_column_text(query, index) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(query, index))), as: UTF8.self)
            })
        }
    }
    func scalar(_ sql: String, _ values: [String?] = []) throws -> String? { try rows(sql, values).first?.first ?? nil }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
