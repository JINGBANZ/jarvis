#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

public struct CoachingReplayExecutor {
    let suite: String
    let target: BrainTarget
    let coach: any BrainClient
    let summarizer: (any BrainClient)?
    let screen: any ScreenCapturing
    let judge: any BrainClient

    public init(suite: String, target: BrainTarget, coach: any BrainClient,
                summarizer: (any BrainClient)? = nil, judge: any BrainClient, screen: any ScreenCapturing) {
        self.suite = suite; self.target = target; self.coach = coach
        self.summarizer = summarizer; self.judge = judge; self.screen = screen
    }

    public func run(_ catalog: CoachingReplayCatalog, metadata: [String: String], output: URL) async throws -> EvaluationSuiteReport {
        var results: [EvaluationDecisionResult] = []
        for episode in catalog.episodes {
            let clock = ReplayClock()
            let transcript = RollingTranscript()
            let overlay = ReplayOverlay(clock: clock)
            let screen = ReplayScreen(base: self.screen)
            let audit = ReplayAttemptAudit(episodeID: episode.id, clock: clock, overlay: overlay, screen: screen)
            let milestoneBrain = ReplayMilestoneBrain(base: coach)
            let driver = CoachDriver(config: .default, transcript: transcript,
                route: .init(targets: [.init(target: target, brain: milestoneBrain, summarizer: summarizer)]),
                screen: screen, overlay: overlay, clock: clock, coachingAttempts: audit)
            var priorReplies: [VisibleEvaluationReply] = []
            var priorTranscript: [String] = []
            var priorScreens: [String] = []
            for decision in episode.decisions {
                overlay.reset(); audit.begin()
                for event in decision.events where event.milestone == nil {
                    Self.inject(event, clock: clock, transcript: transcript, driver: driver, screen: screen)
                }
                clock.advance(to: decision.triggerAt)
                let milestones = decision.events.filter { $0.milestone == "attemptStarted" }
                await milestoneBrain.arm {
                    for event in milestones {
                        Self.inject(event, clock: clock, transcript: transcript, driver: driver, screen: screen)
                    }
                    if !milestones.isEmpty {
                        // Admission is awaited while the first provider request is held at its boundary.
                        _ = await driver.handleTrigger(.turnEnd, transcriptBoundary: transcript.count)
                    }
                }
                let started = Date()
                let (outcome, executionError) = await Self.executeBounded(driver: driver,
                    trigger: decision.quietSeconds.map { .silence(secondsQuiet: $0) } ?? .turnEnd)
                let providerWallSeconds = Date().timeIntervalSince(started)
                let attempts = audit.events
                let runCompleted = [.spoke, .silentByModel, .skippedFillerOnly].contains(outcome)
                    && !attempts.isEmpty && attempts.allSatisfy(\.completed)
                let contracts = [(decision.id, decision.expectation, decision.gradingGoal)]
                    + (decision.automaticFollowups ?? []).map { ($0.id, $0.expectation, $0.gradingGoal) }
                for (index, contract) in contracts.enumerated() {
                    let attempt = attempts.indices.contains(index) ? attempts[index] : nil
                    let completed = runCompleted && attempts.count == contracts.count && attempt?.completed == true
                    let replies = attempts.count == contracts.count ? (attempt?.replies ?? []) : (index == 0 ? overlay.visible : [])
                    let evidence = EvaluationDecisionEvidence(completed: completed, outcome: attempt?.outcome ?? String(describing: outcome),
                        replies: replies, attempts: attempts, providerWallSeconds: providerWallSeconds)
                    var verdict: InterventionVerdict?
                    var gradingError: String? = executionError
                    if completed && !replies.isEmpty, let attempt {
                        do {
                            let encoder = JSONEncoder()
                            let prior = String(decoding: try encoder.encode(priorReplies), as: UTF8.self)
                            let observed = String(decoding: try encoder.encode(attempt), as: UTF8.self)
                            verdict = try await InterventionVerdict.judge(client: judge, input:
                                "Goal: \(contract.2)\nPreviously available transcript: \(priorTranscript.joined(separator: "\n"))\nPreviously observed screens: \(priorScreens.joined(separator: "\n"))\nAvailable transcript and actually observed screens/replies: \(observed)\nPrior visible replies: \(prior)")
                        } catch { gradingError = ProviderMessageRedaction.redact(error.localizedDescription) }
                    }
                    results.append(.init(id: episode.decisions.count > 1 || contracts.count > 1 ? "\(episode.id)/\(contract.0)" : episode.id,
                        expectation: contract.1, evidence: evidence, verdict: verdict, error: gradingError))
                    priorReplies += replies
                    priorTranscript += attempt?.transcript ?? []
                    priorScreens += attempt?.observedScreens ?? []
                    try EvaluationSuiteReport(suite: suite, results: results, metadata: metadata, runErrors: ["Run is not sealed; audit health pending"]).write(to: output)
                }
            }
            await driver.cancelBackgroundWork()?.value
        }
        return EvaluationSuiteReport(suite: suite, results: results, metadata: metadata)
    }

    private static func executeBounded(driver: CoachDriver, trigger: TriggerReason) async -> (TurnOutcome, String?) {
        do {
            let outcome = try await withThrowingTaskGroup(of: TurnOutcome.self) { group in
                group.addTask { await driver.handleTrigger(trigger) }
                group.addTask {
                    try await Task.sleep(for: .seconds(180))
                    throw NSError(domain: "evaluation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Replay decision exceeded its 180-second wall deadline"])
                }
                defer { group.cancelAll() }
                return try await group.next() ?? .cancelled
            }
            return (outcome, nil)
        } catch { return (.cancelled, ProviderMessageRedaction.redact(error.localizedDescription)) }
    }

    private static func inject(_ event: CoachingReplayCatalog.Event, clock: ReplayClock,
                               transcript: RollingTranscript, driver: CoachDriver, screen: ReplayScreen) {
        clock.advance(to: event.at)
        let speaker: Speaker = event.speaker == "them" ? .them : .me
        switch event.kind {
        case .transcript:
            transcript.append(.init(speaker: speaker, text: event.text ?? "", at: event.spokenAt ?? event.at, endedAt: event.spokenEndAt ?? event.at))
        case .speechPending: driver.updateTranscriptionWork(.pending(since: event.spokenAt), for: speaker)
        case .speechSettled: driver.updateTranscriptionWork(.settled, for: speaker)
        case .screen: screen.update(event.text ?? "")
        }
    }
}

#endif
