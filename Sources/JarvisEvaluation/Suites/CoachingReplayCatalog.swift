import Foundation

public struct CoachingReplayCatalog: Codable, Sendable {
    public let version: String
    public let rubricVersion: String
    public let episodes: [Episode]
    public struct Episode: Codable, Sendable {
        public let id: String
        public let decisions: [Decision]
    }
    public struct Decision: Codable, Sendable {
        public let id: String
        public let expectation: EvaluationDecisionResult.Expectation
        public let gradingGoal: String
        public let events: [Event]
        public let triggerAt: Double
        public let quietSeconds: Double?
        public let automaticFollowups: [Followup]?
    }
    public struct Followup: Codable, Sendable {
        public let id: String
        public let expectation: EvaluationDecisionResult.Expectation
        public let gradingGoal: String
    }
    public struct Event: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case transcript, speechPending, speechSettled, screen }
        public let kind: Kind
        public let at: Double
        public let spokenAt: Double?
        public let speaker: String?
        public let text: String?
        public let milestone: String?
    }
    public static func load(from url: URL) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.version == "intervention-v1", catalog.rubricVersion == "intervention-v1",
              !catalog.episodes.isEmpty,
              Set(catalog.episodes.map(\.id)).count == catalog.episodes.count else { throw Failure.invalidCatalog }
        for episode in catalog.episodes {
            guard !episode.id.isEmpty, !episode.id.contains("/"), !episode.decisions.isEmpty,
                  Set(episode.decisions.map(\.id)).count == episode.decisions.count else { throw Failure.invalidCatalog }
            var lastBoundary = 0.0
            for decision in episode.decisions {
                guard !decision.id.isEmpty, !decision.id.contains("/"), decision.triggerAt.isFinite,
                      decision.triggerAt >= lastBoundary, !decision.gradingGoal.isEmpty, !decision.events.isEmpty,
                      decision.quietSeconds.map({ $0.isFinite && $0 > 0 }) ?? true else { throw Failure.invalidCatalog }
                var lastArrival = lastBoundary
                var pending = Set<String>()
                var milestoneStarted = false
                for event in decision.events {
                    if event.milestone != nil && !milestoneStarted {
                        guard pending.isEmpty else { throw Failure.invalidCatalog }
                        milestoneStarted = true
                    }
                    guard !milestoneStarted || event.milestone != nil else { throw Failure.invalidCatalog }
                    guard event.at.isFinite, event.at >= lastArrival,
                          event.spokenAt.map({ $0.isFinite && $0 >= 0 && $0 <= event.at }) ?? true,
                          event.milestone == nil || event.milestone == "attemptStarted",
                          event.milestone == nil ? event.at <= decision.triggerAt : event.at >= decision.triggerAt,
                          event.speaker.map({ $0 == "me" || $0 == "them" }) ?? (event.kind == .screen) else { throw Failure.invalidCatalog }
                    if event.kind == .transcript || event.kind == .screen {
                        guard event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw Failure.invalidCatalog }
                    }
                    if event.kind == .speechPending { pending.insert(event.speaker!) }
                    if event.kind == .speechSettled { pending.remove(event.speaker!) }
                    lastArrival = event.at
                }
                guard pending.isEmpty else { throw Failure.invalidCatalog }
                let followups = decision.automaticFollowups ?? []
                guard Set(followups.map(\.id)).count == followups.count,
                      !followups.contains(where: { $0.id == decision.id || $0.id.isEmpty || $0.id.contains("/") || $0.gradingGoal.isEmpty }),
                      decision.events.contains(where: { $0.milestone != nil }) == !followups.isEmpty else { throw Failure.invalidCatalog }
                lastBoundary = max(decision.triggerAt, lastArrival)
            }
        }
        return catalog
    }
    public enum Failure: Error { case invalidCatalog }
}
