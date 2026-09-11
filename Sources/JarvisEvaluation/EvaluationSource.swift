import Foundation

public enum EvaluationSource: Sendable, Equatable {
    case localCheckout(URL)
    case release(version: String)

    /// Build identity chooses the path; session identity chooses the release version.
    public static func resolve(isDevelopmentBuild: Bool, bundleURL: URL,
                               recordedVersion: String?) -> Self? {
        if isDevelopmentBuild {
            return .localCheckout(bundleURL.deletingLastPathComponent())
        }
        return recordedVersion.map { .release(version: $0) }
    }

    public var workspaceProvenance: String {
        switch self {
        case .localCheckout:
            "This workspace is a live development checkout. It may have changed since this session was recorded, including uncommitted edits, so weigh whether code you cite could have been what actually ran."
        case .release(let version):
            "This workspace is the released source for Jarvis \(version), the exact code that produced this session. It carries no git history."
        }
    }

    public static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#,
                      options: .regularExpression) != nil
    }
}
