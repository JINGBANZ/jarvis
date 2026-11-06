import Foundation

public struct EvaluationAttemptEvidence: Codable, Sendable {
    public var episodeID: String
    public var startedWallAt: Double
    public var finishedWallAt: Double?
    public var id: Int
    public var provider: String
    public var model: String
    public var transcript: [String]
    public var terminal: String?
    public var outcome: String?
    public var startedAt: Double
    public var finishedAt: Double?
    public var replies: [VisibleEvaluationReply]
    public var observedScreens: [String]
    public init(episodeID: String, startedWallAt: Double, finishedWallAt: Double? = nil, id: Int, provider: String, model: String, transcript: [String], terminal: String? = nil,
                outcome: String? = nil, startedAt: Double, finishedAt: Double? = nil,
                replies: [VisibleEvaluationReply] = [], observedScreens: [String] = []) {
        self.episodeID = episodeID; self.startedWallAt = startedWallAt; self.finishedWallAt = finishedWallAt
        self.id = id; self.provider = provider; self.model = model; self.transcript = transcript
        self.terminal = terminal; self.outcome = outcome; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.replies = replies; self.observedScreens = observedScreens
    }
    public var completed: Bool { terminal == "speak" || terminal == "stay_silent" || terminal == "skipped_filler" }
}
