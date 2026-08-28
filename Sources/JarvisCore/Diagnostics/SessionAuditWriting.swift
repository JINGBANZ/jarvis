import Foundation

/// Disk and Console edge owned exclusively by `SessionAuditWorker`.
///
/// Console emission lives here rather than at the `jlog` call site because it is persistence-grade
/// work: `NSLog` formats, takes a process-wide lock, and writes to the unified log. Behind this
/// protocol it runs on the worker, and a test can observe it deterministically.
protocol SessionAuditWriting: Sendable {
    func openSession(at directory: URL, initialHealth: Data) throws
    func append(_ data: Data, filename: String, in directory: URL) throws
    func replaceHealth(_ data: Data, in directory: URL) throws
    func emitToConsole(_ message: String)
}
