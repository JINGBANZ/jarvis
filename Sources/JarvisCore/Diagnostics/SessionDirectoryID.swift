import Foundation

/// The persisted session directory identity. Build prefixes never participate in time ordering.
public struct SessionDirectoryID: Sendable, Equatable {
    public let rawValue: String
    public let chronologyKey: String
    public let releaseVersion: String?
    public let isDevelopment: Bool

    /// Accept both named builds and timestamp-only sessions already stored on disk.
    public init?(_ value: String) {
        guard let match = value.wholeMatch(of:
            /(?:(dev|v[0-9]+\.[0-9]+\.[0-9]+)-)?([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9A-Za-z]{4})/)
        else { return nil }
        rawValue = value
        chronologyKey = String(match.2)
        isDevelopment = match.1 == "dev"
        releaseVersion = match.1.flatMap { $0.first == "v" ? String($0.dropFirst()) : nil }
    }

    public var label: String {
        let parts = chronologyKey.split(separator: "_")
        return "\(parts[0]) \(parts[1].replacingOccurrences(of: "-", with: ":"))"
    }

    /// Pure name construction: no extra disk write, Git process, or source preparation at Start.
    public static func make(isDevelopmentBuild: Bool, version: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let identity = "\(formatter.string(from: date))_\(UUID().uuidString.prefix(4))"
        if isDevelopmentBuild { return "dev-\(identity)" }
        if let version, isValidReleaseVersion(version) { return "v\(version)-\(identity)" }
        // Missing build metadata must not make Start or later history discovery fail.
        return identity
    }

    public static func isValidReleaseVersion(_ version: String) -> Bool {
        version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil
    }
}
