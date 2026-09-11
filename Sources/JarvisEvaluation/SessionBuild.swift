import Foundation

/// Immutable build identity, written at session creation independently of audit health.
public struct SessionBuild: Codable, Sendable {
    public static let filename = "session-build.json"
    public let version: String
    public let format: Int

    public static func write(in directory: URL, isDevelopmentBuild: Bool,
                             version: String?) throws {
        guard !isDevelopmentBuild else { return }
        guard let version, EvaluationSource.isValidVersion(version) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let data = try JSONEncoder().encode(Self(version: version, format: 1))
        guard FileManager.default.createFile(
            atPath: directory.appendingPathComponent(filename).path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func read(in directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              let build = try? JSONDecoder().decode(Self.self, from: data),
              build.format == 1 else { return nil }
        return build
    }
}
