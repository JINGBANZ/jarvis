import Foundation
import JarvisCore

extension TranscriptionBenchmarkRunner {
    func runTurns(
        fixtures: SyntheticSpeechFixtures
    ) async throws -> TranscriptionBenchmark.Summary {
        var results: [TranscriptionBenchmark.TurnsSummary] = []
        for (armIndex, arm) in TranscriptionBenchmark.turnArms.enumerated() {
            try Task.checkCancellation()
            guard !isAbortRequested else { throw Failure.benchmarkAborted }
            TranscriptionBenchmarkFiles.writeProgress(
                phase: "turns-arm",
                detail: "\(armIndex + 1)/\(TranscriptionBenchmark.turnArms.count): \(arm.id)",
                to: options.outputDirectory)
            if arm.provider == .openAI, apiKey == nil {
                results.append(unavailableTurns(
                    arm: arm,
                    reason: Failure.apiKeyUnavailable.description))
                continue
            }

            let appleLocale: Locale?
            if arm.provider == .appleSpeech {
                do {
                    appleLocale = try await prepareAppleLocale(arm.localeIdentifier ?? "")
                } catch {
                    try Task.checkCancellation()
                    guard !isAbortRequested else { throw Failure.benchmarkAborted }
                    results.append(unavailableTurns(
                        arm: arm,
                        reason: String(describing: error)))
                    continue
                }
            } else {
                appleLocale = nil
            }

            results.append(await runTurns(
                arm: arm,
                appleLocale: appleLocale,
                fixtures: fixtures))
        }
        return .init(
            mode: TranscriptionBenchmarkOptions.Mode.turns.rawValue,
            repetitionsPerArm: options.repetitions,
            arms: [],
            turns: results)
    }

    private func runTurns(
        arm: TranscriptionBenchmark.Arm,
        appleLocale: Locale?,
        fixtures: SyntheticSpeechFixtures
    ) async -> TranscriptionBenchmark.TurnsSummary {
        let recorder = TranscriptionBenchmarkEventRecorder(abortMarker: abortMarker)
        let session = makeSession(arm: arm, appleLocale: appleLocale, recorder: recorder)
        relay.install(session) { [recorder] sequence, samples in
            recorder.recordCapture(sequence: sequence, samples: samples)
        }
        session.connect()
        var windows: [TranscriptionBenchmark.TurnWindow] = []
        var failure: String?
        do {
            _ = try await recorder.waitForReady(
                timeout: arm.provider == .appleSpeech ? 60 : 20)
            try await Task.sleep(for: .milliseconds(150))
            for phrase in arm.orderedPhrases {
                // A provider may split one turn across several finals, so this turn's own minimum
                // starts from what the session already delivered.
                let priorFinalCount = recorder.snapshot().events.count { $0.kind == .finalized }
                let spoken = try await play(try fixtures.fixture(for: phrase).fileURL)
                _ = try await play(fixtures.silenceURL)
                windows.append(.init(
                    phrase: phrase,
                    startedAt: spoken.startedAt,
                    speechEndedAt: spoken.endedAt))
                // Each turn's finals must land before the next turn speaks, because a final is
                // attributed to whichever turn was speaking when it arrived.
                try await recorder.waitForFinalStreamToSettle(
                    minimumCount: priorFinalCount + 1,
                    quietPeriod: 1,
                    timeout: 20)
            }
        } catch {
            failure = isAbortRequested
                ? Failure.benchmarkAborted.description
                : String(describing: error)
            jlog("Jarvis benchmark: turns arm failed (\(arm.id)): \(error)")
        }
        relay.install(nil)
        session.stop()

        let snapshot = recorder.snapshot()
        return TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows,
            events: snapshot.events,
            captureObservations: snapshot.captureObservations,
            connectionStates: snapshot.states,
            failure: failure ?? snapshot.terminalFailure.map {
                TranscriptionBenchmarkEventRecorder.Failure.terminal($0).description
            }))
    }

    private func play(
        _ fileURL: URL
    ) async throws -> (startedAt: TimeInterval, endedAt: TimeInterval) {
        try await player.play(
            fileURL,
            abortingWhen: { [abortMarker] in
                FileManager.default.fileExists(atPath: abortMarker.path)
            })
    }

    private func unavailableTurns(
        arm: TranscriptionBenchmark.Arm,
        reason: String
    ) -> TranscriptionBenchmark.TurnsSummary {
        TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: [],
            events: [],
            failure: reason))
    }
}
