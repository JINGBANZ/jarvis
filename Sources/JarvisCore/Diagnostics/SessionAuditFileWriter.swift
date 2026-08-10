import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owner-only file implementation of the session-audit disk edge.
struct SessionAuditFileWriter: SessionAuditWriting {
    func openSession(at directory: URL, initialHealth: Data) throws {
        try createOwnerOnlyFile(
            directory.appendingPathComponent(FileSessionAudit.brainTrafficFilename))
        try createOwnerOnlyFile(
            directory.appendingPathComponent(FileSessionAudit.coachingAttemptsFilename))
        _ = try replaceHealth(initialHealth, in: directory) { true }
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

    @discardableResult
    func replaceHealth(
        _ data: Data,
        in directory: URL,
        shouldCommit: @Sendable () -> Bool
    ) throws -> Bool {
        let destination = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        let temporary = directory.appendingPathComponent(
            ".\(FileSessionAudit.healthFilename).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }

        guard shouldCommit() else { return false }

        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }

    private func createOwnerOnlyFile(_ url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
