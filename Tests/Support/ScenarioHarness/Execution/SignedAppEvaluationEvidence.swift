#if JARVIS_LIVE_E2E
import Foundation

public struct SignedAppEvaluationEvidence {
    public let directory: URL
    public let results: String
    public let finished: Bool
    public init(directory: URL, results: String, finished: Bool) {
        self.directory = directory; self.results = results; self.finished = finished
    }
}

#endif
