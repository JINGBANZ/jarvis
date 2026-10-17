import Foundation
import CryptoKit
import SQLite3

struct ReferenceRevisionWriter {
    static func write(databasePath: String, revision: String, document: String, sourceHash: String, text: String) throws {
        let bytes = Data(text.utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let database = try ReferenceDatabase(path: databasePath)
        try database.transaction {
            try database.execute("INSERT OR IGNORE INTO revisions(id,document_id,source_hash,processor,scalar_count,text_hash,ready,last_used) VALUES(?,?,?,?,?,?,0,strftime('%s','now'))", [revision, document, sourceHash, ReferenceConversionPool.processorVersion, String(text.unicodeScalars.count), digest])
            if try database.scalar("SELECT ready FROM revisions WHERE id=?", [revision]) == "0" {
                try database.execute("DELETE FROM content_parts WHERE revision_id=?", [revision])
            }
        }
        guard try database.scalar("SELECT ready FROM revisions WHERE id=?", [revision]) == "0" else { return }
        var position = 0
        var part = 0
        while position < bytes.count {
            try Task.checkCancellation()
            let count = min(524_288, bytes.count - position)
            try database.transaction {
                let insert = try database.statement("INSERT INTO content_parts(revision_id,part,bytes) VALUES(?,?,?)", [revision, String(part)])
                defer { sqlite3_finalize(insert) }
                let code = bytes.withUnsafeBytes { raw in
                    sqlite3_bind_blob(insert, 3, raw.baseAddress!.advanced(by: position), Int32(count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard code == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw database.failure() }
            }
            position += count
            part += 1
        }
    }
}
