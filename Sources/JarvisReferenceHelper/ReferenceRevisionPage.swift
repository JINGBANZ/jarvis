import Foundation
import CryptoKit
import SQLite3

struct ReferenceRevisionPage: Sendable {
    let text: String
    let totalScalars: Int

    static func load(databasePath: String, revision: String, offset: Int) throws -> Self {
        let database = try ReferenceDatabase(path: databasePath, readOnly: true)
        try database.execute("BEGIN")
        defer { try? database.execute("ROLLBACK") }
        guard let row = try database.rows("SELECT scalar_count,text_hash FROM revisions WHERE id=? AND ready=1", [revision]).first,
              let total = row[0].flatMap(Int.init), let expectedHash = row[1] else { throw ReferenceStoreError.unavailable }
        guard offset >= 0, offset <= total else { throw ReferenceStoreError.invalid_offset }
        let query = try database.statement("SELECT bytes FROM content_parts WHERE revision_id=? ORDER BY part", [revision])
        defer { sqlite3_finalize(query) }
        var digest = SHA256()
        var scalar = -1
        var result = Data()
        while true {
            try Task.checkCancellation()
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(query, 0) else { throw ReferenceStoreError.unavailable }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(query, 0)))
            digest.update(data: Data(bytes))
            if scalar < offset + 16_000 {
                for byte in bytes {
                    if byte & 0xc0 != 0x80 { scalar += 1 }
                    if scalar >= offset + 16_000 { break }
                    if scalar >= offset { result.append(byte) }
                }
            }
        }
        let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash, let text = String(data: result, encoding: .utf8) else { throw ReferenceStoreError.unavailable }
        return Self(text: text, totalScalars: total)
    }
}
