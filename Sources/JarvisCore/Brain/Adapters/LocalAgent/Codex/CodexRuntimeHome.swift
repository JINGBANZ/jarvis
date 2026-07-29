import Foundation

/// Creates the credential-bearing private home used only by the Codex coaching app-server.
///
/// The home lives outside both the source checkout and retained session directories. A crash can
/// therefore leave an owner-only runtime directory behind without exposing its auth symlink to the
/// completed-session evaluator.
enum CodexRuntimeHome {
    static let directoryPrefix = "codex-runtime-"
    private static let legacySessionDirectoryPrefix = ".codex-runtime-"

    static var defaultBaseDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("agent-runtimes", isDirectory: true)
    }

    static var defaultAuthFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/auth.json")
    }

    static func create(
        in baseDirectory: URL = defaultBaseDirectory,
        authFile: URL = defaultAuthFile
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: baseDirectory.path)

        let directory = baseDirectory.appendingPathComponent(
            "\(directoryPrefix)\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            if fileManager.fileExists(atPath: authFile.path) {
                try fileManager.createSymbolicLink(
                    at: directory.appendingPathComponent("auth.json"),
                    withDestinationURL: authFile)
            }
            return directory
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// Old review builds created the auth-bearing home inside a session. Evaluation must fail closed
    /// if one cannot be removed, because that session is about to be exposed to an agentic auditor.
    static func removeLegacyHomes(from sessionDirectory: URL) throws {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil)
        for child in children
        where child.lastPathComponent.hasPrefix(legacySessionDirectoryPrefix) {
            try fileManager.removeItem(at: child)
        }
    }
}
