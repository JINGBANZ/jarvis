import Foundation
import JarvisCore

@MainActor
final class PendingReferenceAdmission {
    let startID: UUID
    private let library: ReferenceLibrary
    private let task: Task<ReferenceAdmissionResult, Error>

    init(library: ReferenceLibrary, deadline: ContinuousClock.Instant, startID: UUID = UUID()) {
        self.startID = startID
        self.library = library
        task = Task { try await library.admit(startID: startID, deadline: deadline) }
    }

    func result() async throws -> ReferenceAdmissionResult { try await task.value }

    func cancel() {
        task.cancel()
        library.abandon(startID: startID)
    }
}
