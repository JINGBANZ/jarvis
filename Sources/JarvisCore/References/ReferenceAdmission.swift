import Foundation

public struct ReferenceAdmission: Sendable {
    public enum Metadata: Equatable, Sendable {
        case preparing(generation: Int)
        case ready(generation: Int, count: Int)
        case failed(generation: Int)
    }
    public enum Decision: Equatable, Sendable {
        case wait, admit(generation: Int), omit(ReferenceOmissionReason)
    }

    public let deadline: Duration
    public init(startedAt: Duration, budget: Duration = .seconds(2)) { deadline = startedAt + budget }

    public func decide(now: Duration, enabled: Bool, generation: Int, metadata: Metadata?) -> Decision {
        guard enabled else { return .omit(.disabled) }
        guard now < deadline else { return .omit(.timeout) }
        switch metadata {
        case .ready(let prepared, let count) where prepared == generation:
            return count == 0 ? .omit(.empty) : .admit(generation: generation)
        case .failed(let prepared) where prepared == generation: return .omit(.failed)
        default: return .wait
        }
    }
}
