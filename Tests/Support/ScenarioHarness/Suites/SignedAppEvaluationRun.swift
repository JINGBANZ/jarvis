#if JARVIS_LIVE_E2E
import Foundation

public struct SignedAppEvaluationRun: Sendable {
    public let scenarioID: String
    public let reportDirectory: URL
    public let evidenceDirectory: URL

    public init(runDirectory: URL, repeatIndex: Int) {
        scenarioID = "A-repeat-\(repeatIndex)"
        reportDirectory = runDirectory.appendingPathComponent("repeat-\(repeatIndex)", isDirectory: true)
        evidenceDirectory = runDirectory.appendingPathComponent(scenarioID, isDirectory: true)
    }
}

#endif
