import Foundation

/// Disk edge owned exclusively by `SessionAuditWorker`.
protocol SessionAuditWriting: Sendable {
    func openSession(at directory: URL, initialHealth: Data) throws
    func append(_ data: Data, filename: String, in directory: URL) throws
    func replaceHealth(_ data: Data, in directory: URL) throws
}
