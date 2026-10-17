import Foundation

struct CapturedReference: Sendable {
    let snapshotURL: URL
    let sourceHash: String
    let format: String
    let sourceIdentity: String
    let sourceState: String
}
