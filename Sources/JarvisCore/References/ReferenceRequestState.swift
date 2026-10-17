import Foundation

public struct ReferenceRequestState: Sendable {
    private var pending: Set<UUID> = []
    private var cancelled: Set<UUID> = []
    public init() {}
    public mutating func begin(_ id: UUID) throws {
        guard !pending.contains(id), !cancelled.contains(id) else {
            throw ReferenceProtocolError.unexpectedResponse
        }
        pending.insert(id)
    }
    public mutating func cancel(_ id: UUID) {
        if pending.remove(id) != nil { cancelled.insert(id) }
    }
    /// A cancelled call may complete once; all duplicates and unknown IDs fail closed.
    public mutating func receive(_ id: UUID) throws -> Bool {
        if pending.remove(id) != nil { return true }
        if cancelled.remove(id) != nil { return false }
        throw ReferenceProtocolError.unexpectedResponse
    }
    public mutating func reset() { pending.removeAll(); cancelled.removeAll() }
}
