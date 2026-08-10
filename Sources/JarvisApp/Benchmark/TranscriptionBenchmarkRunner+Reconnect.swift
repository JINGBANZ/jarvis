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
            recorder: recorder,
            reconnectTiming: true)
        relay.install(session) { [recorder] sequence, samples in
            recorder.recordCapture(sequence: sequence, samples: samples)
        }
        session.connect()
        var failure: String?
        var networkDisableAcknowledged = false
        var restoreRequested = false
        do {
            let firstReady = try await recorder.waitForReady(timeout: 20)
            try requestOperator(action: "disable-network", model: model)
            try await waitForOperator(
                action: "disable-network", model: model, timeout: 600)
            networkDisableAcknowledged = true
            try await recorder.waitForReconnect(timeout: 15)

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

            try requestOperator(action: "restore-network", model: model)
            restoreRequested = true
            try await waitForOperator(
                action: "restore-network", model: model, timeout: 600)
            let replacementReady = try await recorder.waitForReady(
                minimumGeneration: firstReady.generation + 1,
                timeout: 60)
            try await recorder.waitForRecognizedReconnectPhrases(
                phraseIDs,
                inGeneration: replacementReady.generation,
                timeout: 40)
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            let aborted = isAbortRequested
            failure = aborted
                ? Failure.operatorAborted.description
                : String(describing: error)
            jlog("Jarvis benchmark: reconnect failed (\(model.rawValue)): \(error)")
            // Once the operator may have disabled networking, always return control to the script
            // and wait for an explicit restore acknowledgement—even when outage detection or audio
            // validation failed early. The harness never leaves the operator waiting while offline.
            if !aborted && networkDisableAcknowledged && !restoreRequested {
                try? requestOperator(action: "restore-network", model: model)
                try? await waitForOperator(
                    action: "restore-network", model: model, timeout: 600)
            }
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

    private func requestOperator(
        action: String,
        model: OpenAITranscriptionModel
    ) throws {
        try checkForAbort()
        TranscriptionBenchmarkFiles.writeProgress(
            phase: "waiting-for-\(action)",
            model: model.rawValue,
            to: options.outputDirectory)
        try TranscriptionBenchmarkFiles.createMarker(
            named: "request-\(action)--\(model.rawValue)",
            in: options.outputDirectory)
    }

    private func waitForOperator(
        action: String,
        model: OpenAITranscriptionModel,
        timeout: TimeInterval
    ) async throws {
        let acknowledgement = options.outputDirectory.appendingPathComponent(
            "ack-\(action)--\(model.rawValue)")
        let deadline = clock.now() + timeout
        while clock.now() < deadline {
            try Task.checkCancellation()
            try checkForAbort()
            if FileManager.default.fileExists(atPath: acknowledgement.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.operatorTimedOut("\(action) for \(model.rawValue)")
    }

    private var abortMarker: URL {
        options.outputDirectory.appendingPathComponent("abort")
    }

    private var isAbortRequested: Bool {
        FileManager.default.fileExists(atPath: abortMarker.path)
    }

    private func checkForAbort() throws {
        if isAbortRequested { throw Failure.operatorAborted }
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
