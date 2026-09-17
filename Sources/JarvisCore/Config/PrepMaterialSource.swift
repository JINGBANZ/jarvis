import Foundation

public struct PrepMaterialSource: Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let isDirectory: Bool

    public init(id: UUID = UUID(), path: String, isDirectory: Bool) {
        self.id = id
        self.path = path
        self.isDirectory = isDirectory
    }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Checked live, never cached: the user's notes can move or be deleted at any time.
    public func exists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
