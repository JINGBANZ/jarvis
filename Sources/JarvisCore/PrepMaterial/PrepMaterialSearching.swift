import Foundation

public protocol PrepMaterialSearching: Sendable {
    /// Best first; empty when nothing scores.
    func search(query: String) -> [PrepMaterialSearchResult]
    func read(documentID: String, offset: Int) -> PrepMaterialPage?
}
