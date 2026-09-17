import Foundation

/// Console emission lives here, not at the `jlog` call site, because `NSLog` takes a process-wide
/// lock. Behind this protocol it runs on the worker.
protocol SessionAuditWriting: Sendable {
    func openSession(at directory: URL, initialHealth: Data) throws
    func append(_ data: Data, filename: String, in directory: URL) throws
    /// Creates one owner-only file with exactly these bytes.
    func write(_ data: Data, filename: String, in directory: URL) throws
    func replaceHealth(_ data: Data, in directory: URL) throws
    func emitToConsole(_ message: String)
}
