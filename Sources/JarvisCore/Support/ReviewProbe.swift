import Foundation

/// Scratch type to verify the centralized reusable PR-review workflow end-to-end.
/// Deliberately violates a CLAUDE.md rule so the reviewer has something to flag. Safe to delete.
struct ReviewProbe: @unchecked Sendable {
    var count: Int
}
