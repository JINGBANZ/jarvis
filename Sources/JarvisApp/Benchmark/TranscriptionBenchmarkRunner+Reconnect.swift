import Foundation
import JarvisCore

extension TranscriptionBenchmarkRunner {
    func runReconnect(
        fixtures: SyntheticSpeechFixtures
    ) async -> TranscriptionBenchmark.Summary {
        guard apiKey != nil else {
            return .init(
                mode: TranscriptionBenchmarkOptions.Mode.reconnect.rawValue,
                repetitionsPerArm: options.repetitions,
                arms: [],
                reconnect: OpenAITranscriptionModel.allCases.map { model in
                    failedReconnect(model: model, error: Failure.apiKeyUnavailable)
                })
        }

        var results: [TranscriptionBenchmark.ReconnectSummary] = []
        for model in OpenAITranscriptionModel.allCases {
            if Task.isCancelled || isAbortRequested { break }
            results.append(await runReconnect(model: model, fixtures: fixtures))
            if isAbortRequested { break }
        }
        return .init(
            mode: TranscriptionBenchmarkOptions.Mode.reconnect.rawValue,
            repetitionsPerArm: options.repetitions,
            arms: [],
            reconnect: results)
    }

    private func runReconnect(
        model: OpenAITranscriptionModel,
        fixtures: SyntheticSpeechFixtures
    ) async -> TranscriptionBenchmark.ReconnectSummary {
        let phraseIDs = ["english-technical", "mandarin-technical"]
        let phrases = phraseIDs.compactMap { id in
            TranscriptionBenchmark.phrases.first { $0.id == id }
        }
        let recorder = TranscriptionBenchmarkEventRecorder(abortMarker: abortMarker)
        let arm = TranscriptionBenchmark.Arm(
            id: "reconnect--\(model.rawValue)",
            provider: .openAI,
            model: model,
            languageProfile: .englishAndMandarinChinese,
            localeIdentifier: nil,
            phrase: phrases[0])
        let session = makeSession(
            arm: arm,
            appleLocale: nil,
            recorder: recorder)
        relay.install(session) { [recorder] sequence, samples in
            recorder.recordCapture(sequence: sequence, samples: samples)
        }
        session.connect()
        var failure: String?
        do {
            let firstReady = try await recorder.waitForReady(timeout: 20)
            guard let realtimeSession = session as? RealtimeTranscriber,
                  realtimeSession.beginBenchmarkTransportInterruption() else {
                throw Failure.transportInterruptionUnavailable
            }
            var transportInterruptionHeld = true
            defer {
                if transportInterruptionHeld {
                    realtimeSession.endBenchmarkTransportInterruption()
                }
            }
            TranscriptionBenchmarkFiles.writeProgress(
                phase: "capturing-scoped-transport-interruption",
                model: model.rawValue,
                to: options.outputDirectory)
            try await recorder.waitForReconnect(timeout: 5)

            for phrase in phrases {
                let fixture = try fixtures.fixture(for: phrase)
                _ = try await player.play(
                    fixture.fileURL,
                    abortingWhen: { [abortMarker] in
                        FileManager.default.fileExists(atPath: abortMarker.path)
                    })
                _ = try await player.play(
                    fixtures.silenceURL,
                    abortingWhen: { [abortMarker] in
                        FileManager.default.fileExists(atPath: abortMarker.path)
                    })
            }

            TranscriptionBenchmarkFiles.writeProgress(
                phase: "releasing-scoped-transport-interruption",
                model: model.rawValue,
                to: options.outputDirectory)
            realtimeSession.endBenchmarkTransportInterruption()
            transportInterruptionHeld = false
            let replacementReady = try await recorder.waitForReady(
                minimumGeneration: firstReady.generation + 1,
                timeout: 60)
            try await recorder.waitForRecognizedReconnectFinalStreamToSettle(
                phraseIDs,
                inGeneration: replacementReady.generation,
                quietPeriod: 1,
                timeout: 40)
        } catch {
            let aborted = isAbortRequested
            failure = aborted
                ? Failure.benchmarkAborted.description
                : String(describing: error)
            jlog("Jarvis benchmark: reconnect failed (\(model.rawValue)): \(error)")
        }
        relay.install(nil)
        session.stop()

        let snapshot = recorder.snapshot()
        return TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: phraseIDs,
            events: snapshot.events,
            captureObservations: snapshot.captureObservations,
            failure: failure)
    }

    private func failedReconnect(
        model: OpenAITranscriptionModel,
        error: Error
    ) -> TranscriptionBenchmark.ReconnectSummary {
        TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: ["english-technical", "mandarin-technical"],
            events: [],
            failure: String(describing: error))
    }
}
