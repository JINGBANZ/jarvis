#if JARVIS_LIVE_E2E
import Foundation

public struct InterventionCalibration: Codable, Sendable {
    public let labelSource: String
    public let examples: [Example]
    public struct Example: Codable, Sendable {
        public let id: String
        public let evidence: String
        public let expected: InterventionVerdict
        public func matches(_ actual: InterventionVerdict) -> Bool {
            actual.confident == expected.confident && actual.grounded == expected.grounded
                && actual.helpful == expected.helpful && actual.redundant == expected.redundant
        }
    }
}

#endif
