import Foundation

public struct EvaluationDecisionEvidence: Codable, Sendable {
    public var assertionsPassed: Bool?
    public var completed: Bool
    public var outcome: String
    public var replies: [VisibleEvaluationReply]
    public var attempts: [EvaluationAttemptEvidence]
    public var providerWallSeconds: Double
    public init(completed: Bool, outcome: String, replies: [VisibleEvaluationReply],
                attempts: [EvaluationAttemptEvidence] = [], providerWallSeconds: Double = 0, assertionsPassed: Bool? = nil) {
        self.assertionsPassed = assertionsPassed
        self.completed = completed; self.outcome = outcome; self.replies = replies
        self.attempts = attempts; self.providerWallSeconds = providerWallSeconds
    }
}
