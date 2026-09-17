import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Every file is created owner-only (0600): sessions hold screen- and audio-derived data.
struct SessionAuditFileWriter: SessionAuditWriting {
    func openSession(at directory: URL, initialHealth: Data) throws {
        try ensureOwnerOnlyFile(
            directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename))
        try ensureOwnerOnlyFile(
            directory.appendingPathComponent(FileSessionAudit.coachingAttemptsFilename))
        try ensureOwnerOnlyFile(
            directory.appendingPathComponent(FileSessionAudit.diagnosticFilename))
        // Created up front so `SessionStore.listSessions()` finds the session before its first row.
        try ensureOwnerOnlyFile(
            directory.appendingPathComponent(ActivityLog.filename))
        try replaceHealth(initialHealth, in: directory)
    }

    func append(_ data: Data, filename: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(filename)
        let handle = try FileHandle(forWritingTo: url)
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    func replaceHealth(_ data: Data, in directory: URL) throws {
        let destination = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        let temporary = directory.appendingPathComponent(
            ".\(FileSessionAudit.healthFilename).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func write(_ data: Data, filename: String, in directory: URL) throws {
        guard FileManager.default.createFile(
            atPath: directory.appendingPathComponent(filename).path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
    }

    func emitToConsole(_ message: String) {
        NSLog("%@", message)
    }

    /// Never truncates, so open can be retried after a health-file failure.
    private func ensureOwnerOnlyFile(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
