import Foundation

/// Scratch type used to verify the automated PR-review workflow end-to-end.
/// Deliberately violates a CLAUDE.md rule so the reviewer has something to flag. Safe to delete.
struct ReviewProbe: @unchecked Sendable {
    var count: Int
}
