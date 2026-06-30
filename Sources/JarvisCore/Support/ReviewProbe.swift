import Foundation

/// Scratch type used to verify the automated PR-review workflow posts inline diff comments.
/// Deliberately violates a CLAUDE.md rule so the reviewer has something to flag. Safe to delete.
struct ReviewProbe: @unchecked Sendable {
    var count: Int
}
