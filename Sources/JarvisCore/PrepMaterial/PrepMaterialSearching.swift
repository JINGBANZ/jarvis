import Foundation

/// One relevant excerpt from the user's configured prep material, plus which source it came from.
public struct PrepMaterialSearchResult: Sendable, Equatable {
    public let sourceDisplayName: String
    public let text: String

    public init(sourceDisplayName: String, text: String) {
        self.sourceDisplayName = sourceDisplayName
        self.text = text
    }
}

/// Looks up the most relevant chunks of the user's prep material for a live coaching question.
///
/// This is the kernel's prep-material port: Core owns the contract and the pure chunking/ranking
/// logic behind it (`PrepMaterialIndex`), while reading the user's files and extracting text from
/// each format (plain text, PDF, Word) live at the macOS edge in JarvisApp, composed once at Session
/// Start — mirrors how `ScreenCapturing` splits the kernel contract from `JarvisScreenCapture`'s
/// concrete edge.
public protocol PrepMaterialSearching: Sendable {
    /// The most relevant chunks for `query`, ranked best first. Empty when nothing scores usefully —
    /// never a thrown error, since this is a pure in-memory lookup against an already-built index.
    func search(query: String) -> [PrepMaterialSearchResult]
}
