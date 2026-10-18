import Foundation

public enum ReferenceAdmissionResult: Sendable {
    public struct Admitted: Sendable {
        public let startID: UUID
        public let sessionID: UUID
        public let session: any DocumentSession
        public let context: SessionContext
        public let accessPolicy: AccessPolicy

        public init(startID: UUID, sessionID: UUID, session: any DocumentSession, context: SessionContext,
                    accessPolicy: AccessPolicy = .documents) {
            self.startID = startID; self.sessionID = sessionID; self.session = session
            self.context = context; self.accessPolicy = accessPolicy
        }
    }
    public struct AccessPolicy: Sendable {
        public let disabledTools: Set<String>
        public init(disabledTools: Set<String>) { self.disabledTools = disabledTools }
        public static let documents = AccessPolicy(disabledTools: [])
    }
    public var startID: UUID {
        switch self { case .admitted(let result): result.startID; case .omitted(let id, _): id }
    }
    case admitted(Admitted)
    case omitted(startID: UUID, reason: ReferenceOmissionReason)
}
