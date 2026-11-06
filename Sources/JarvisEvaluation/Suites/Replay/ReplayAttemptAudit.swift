import Foundation
import JarvisCore

/// @unchecked: storage is lock protected; overlay, screen, and clock synchronize themselves.
final class ReplayAttemptAudit: CoachingAttemptAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EvaluationAttemptEvidence] = []
    private var replyStart = 0
    private var screenStart = 0
    private let episodeID: String
    private let clock: ReplayClock
    private let overlay: ReplayOverlay
    private let screen: ReplayScreen
    init(episodeID: String, clock: ReplayClock, overlay: ReplayOverlay, screen: ReplayScreen) {
        self.episodeID = episodeID
        self.clock = clock; self.overlay = overlay; self.screen = screen
    }
    var events: [EvaluationAttemptEvidence] { lock.withLock { storage } }
    func begin() { lock.withLock { storage = [] } }
    func record(_ event: CoachingAttemptAuditEvent) {
        lock.withLock {
            switch event {
            case .started(let start):
                replyStart = overlay.visible.count; screenStart = screen.observations.count
                storage.append(.init(episodeID: episodeID, startedWallAt: start.date.timeIntervalSince1970, id: start.attemptID, provider: start.target.provider.rawValue,
                    model: start.target.modelID, transcript: start.transcriptLines.map { "\($0.speaker.rawValue) spoken=\($0.at): \($0.text)" }, startedAt: clock.now()))
            case .finished(let end):
                guard let index = storage.lastIndex(where: { $0.id == end.attemptID }) else { return }
                storage[index].terminal = end.terminal.rawValue; storage[index].outcome = String(describing: end.outcome)
                storage[index].finishedAt = clock.now()
                storage[index].finishedWallAt = end.date.timeIntervalSince1970
                storage[index].replies = Array(overlay.visible.dropFirst(replyStart))
                storage[index].observedScreens = Array(screen.observations.dropFirst(screenStart))
            }
        }
    }
}
