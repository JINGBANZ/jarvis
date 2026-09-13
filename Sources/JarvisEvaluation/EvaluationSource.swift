import Foundation
import JarvisCore

public enum EvaluationSource: Sendable, Equatable {
    case localCheckout(URL)
    case release(version: String?, fallbackVersion: String? = nil)

    /// Build identity chooses the path; session identity chooses the release version.
    public static func resolve(isDevelopmentBuild: Bool, bundleURL: URL,
                               sessionID: String, currentVersion: String?) -> Self {
        if isDevelopmentBuild {
            return .localCheckout(bundleURL.deletingLastPathComponent())
        }
        return .release(version: SessionDirectoryID(sessionID)?.releaseVersion,
                        fallbackVersion: currentVersion)
    }

    public var workspaceProvenance: String {
        switch self {
        case .localCheckout:
            "This workspace is a live development checkout. It may have changed since this session was recorded, including uncommitted edits, so weigh whether code you cite could have been what actually ran."
        case .release(let version, _):
            releaseProvenance(using: version)
        }
    }

    public static func isValidVersion(_ version: String) -> Bool {
        SessionDirectoryID.isValidReleaseVersion(version)
    }

    /// State the source actually used, never presenting fallback code as proof of what ran.
    public func releaseProvenance(using actualVersion: String?) -> String {
        guard case .release(let recorded, _) = self else { return workspaceProvenance }
        if let recorded, recorded == actualVersion {
            return "This workspace is the released source for Jarvis \(recorded), the exact code that produced this session. It carries no git history."
        }
        let identity = recorded.map { "This session was recorded with Jarvis \($0)." }
            ?? "This session's recorded Jarvis version is unknown."
        let source = actualVersion.map { "This evaluation uses released source for Jarvis \($0)." }
            ?? "The matching source version is unavailable."
        return "\(identity) \(source) The source may not match the code that produced this session and carries no git history. State this mismatch in the report and qualify source-based findings accordingly."
    }
}
