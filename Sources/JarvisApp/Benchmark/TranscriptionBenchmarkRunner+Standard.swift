import Foundation
import JarvisCore

extension TranscriptionBenchmarkRunner {
    func runStandard(
        fixtures: SyntheticSpeechFixtures
    ) async throws -> TranscriptionBenchmark.Summary {
        var summaries: [TranscriptionBenchmark.ArmSummary] = []
        for (armIndex, arm) in TranscriptionBenchmark.standardArms.enumerated() {
            try Task.checkCancellation()
            TranscriptionBenchmarkFiles.writeProgress(
                phase: "standard-arm",
                detail: "\(armIndex + 1)/\(TranscriptionBenchmark.standardArms.count): \(arm.id)",
                to: options.outputDirectory)
            if arm.provider == .openAI, apiKey == nil {
                summaries.append(.init(
                    arm: arm,
                    repetitions: [],
                    unavailableReason: Failure.apiKeyUnavailable.description))
                continue
            }

            let appleLocale: Locale?
            if arm.provider == .appleSpeech {
                do {
                    appleLocale = try await prepareAppleLocale(
                        arm.localeIdentifier ?? "")
                } catch {
                    summaries.append(.init(
                        arm: arm,
                        repetitions: [],
                        unavailableReason: String(describing: error)))
                    continue
                }
            } else {
                appleLocale = nil
            }

            let fixture = try fixtures.fixture(for: arm.phrase)
            var repetitions: [TranscriptionBenchmark.RepetitionResult] = []
            for repetition in 1...options.repetitions {
                try Task.checkCancellation()
                TranscriptionBenchmarkFiles.writeProgress(
                    phase: "standard-repetition",
                    detail: "\(arm.id) \(repetition)/\(options.repetitions)",
                    to: options.outputDirectory)
                repetitions.append(await runRepetition(
                    arm: arm,
                    repetition: repetition,
                    fixture: fixture,
                    silenceURL: fixtures.silenceURL,
                    appleLocale: appleLocale))
            }
            summaries.append(.init(arm: arm, repetitions: repetitions))
        }
        return .init(
            mode: TranscriptionBenchmarkOptions.Mode.standard.rawValue,
            repetitionsPerArm: options.repetitions,
            arms: summaries)
    }

    private func runRepetition(
        arm: TranscriptionBenchmark.Arm,
        repetition: Int,
        fixture: SyntheticSpeechFixtures.Fixture,
        silenceURL: URL,
        appleLocale: Locale?
    ) async -> TranscriptionBenchmark.RepetitionResult {
        let recorder = TranscriptionBenchmarkEventRecorder()
        let session = makeSession(arm: arm, appleLocale: appleLocale, recorder: recorder)
        let connectStartedAt = clock.now()
        var speechEndedAt = connectStartedAt
        var failure: String?
        relay.install(session) { [recorder] sequence, samples in
            recorder.recordCapture(sequence: sequence, samples: samples)
        }
        session.connect()
        do {
            _ = try await recorder.waitForReady(
                timeout: arm.provider == .appleSpeech ? 60 : 20)
            try await Task.sleep(for: .milliseconds(150))
            speechEndedAt = try await player.play(fixture.fileURL).endedAt
            _ = try await player.play(silenceURL)
            try await recorder.waitForFinalStreamToSettle(
                minimumCount: 1,
                quietPeriod: 1,
                timeout: 20)
        } catch {
            failure = String(describing: error)
            jlog("Jarvis benchmark: repetition failed (\(arm.id) #\(repetition)): \(error)")
        }
        relay.install(nil)
        session.stop()
        let snapshot = recorder.snapshot()
        return TranscriptionBenchmark.evaluate(.init(
            arm: arm,
            repetition: repetition,
            fixtureSHA256: fixture.sha256,
            connectStartedAt: connectStartedAt,
            speechEndedAt: speechEndedAt,
            events: snapshot.events,
            captureObservations: snapshot.captureObservations,
            failure: failure))
    }

    private func prepareAppleLocale(_ identifier: String) async throws -> Locale {
        if let locale = preparedAppleLocales[identifier] { return locale }
        if let failure = appleLocaleFailures[identifier] {
            throw Failure.appleSpeechUnavailable(failure)
        }
        guard #available(macOS 26.0, *) else {
            let detail = "requires macOS 26 or later"
            appleLocaleFailures[identifier] = detail
            throw Failure.appleSpeechUnavailable(detail)
        }
        do {
            let locale = try await AppleSpeechModelPreparation.prepare(
                localeIdentifier: identifier)
            preparedAppleLocales[identifier] = locale
            return locale
        } catch {
            let detail = String(describing: error)
            appleLocaleFailures[identifier] = detail
            throw Failure.appleSpeechUnavailable(detail)
        }
    }
}
