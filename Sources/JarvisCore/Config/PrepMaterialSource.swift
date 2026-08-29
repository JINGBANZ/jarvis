import Foundation

/// One local file or folder the user has pointed Jarvis at as interview prep material — prepared
/// topics and answers the coach can draw on. Jarvis only reads this path; it never copies or
/// modifies the user's notes.
public struct PrepMaterialSource: Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let isDirectory: Bool

    public init(id: UUID = UUID(), path: String, isDirectory: Bool) {
        self.id = id
        self.path = path
        self.isDirectory = isDirectory
    }

    /// The last path component, for display — e.g. "system-design-notes.md" or "Interview Prep".
    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Whether the path still resolves on disk. Checked live rather than cached: the user's notes
    /// live outside Jarvis and can move or be deleted at any time.
    public func exists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
