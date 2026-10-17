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
    public enum AccessPolicy: Sendable { case documents }
    case admitted(Admitted)
    case omitted(startID: UUID, reason: ReferenceOmissionReason)
}
