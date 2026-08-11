import Foundation
import JarvisCore

@MainActor
final class TranscriptionBenchmarkRunner {
    enum Failure: Error, CustomStringConvertible {
        case apiKeyUnavailable
        case appleSpeechUnavailable(String)
        case missingFixture(String)
        case benchmarkAborted
        case transportInterruptionUnavailable
        case acceptanceFailed(String)

        var description: String {
            switch self {
            case .apiKeyUnavailable:
                "OpenAI API key unavailable in the owner-only key file or OPENAI_API_KEY"
            case .appleSpeechUnavailable(let detail): "Apple Speech unavailable: \(detail)"
            case .missingFixture(let id): "Missing benchmark fixture \(id)"
            case .benchmarkAborted: "Transcription benchmark aborted"
            case .transportInterruptionUnavailable:
                "Could not interrupt the active transcription transport"
            case .acceptanceFailed(let detail): "Benchmark acceptance failed: \(detail)"
            }
        }
    }

    let options: TranscriptionBenchmarkOptions
    let clock = SystemClock()
    let relay = TranscriptionBenchmarkSessionRelay()
    let player = SyntheticAudioPlayer()
    let networkDiagnostics = NetworkPathDiagnostics()
    let apiKey = ChainedSecretStore([FileSecretStore(), EnvSecretStore()]).apiKey()
    var preparedAppleLocales: [String: Locale] = [:]
    var appleLocaleFailures: [String: String] = [:]

    var abortMarker: URL {
        options.outputDirectory.appendingPathComponent("abort")
    }

    var isAbortRequested: Bool {
        FileManager.default.fileExists(atPath: abortMarker.path)
    }

    init(options: TranscriptionBenchmarkOptions) {
        self.options = options
    }

    func run() async throws {
        try TranscriptionBenchmarkFiles.prepareOutputDirectory(options.outputDirectory)
        try TranscriptionBenchmarkRunStore(
            base: options.outputDirectory.deletingLastPathComponent(),
            current: options.outputDirectory
        ).pruneToMostRecent(TranscriptionBenchmark.retainedRunCount)
        JarvisLog.enableFileLogging(directory: options.outputDirectory)
        networkDiagnostics.start()
        TranscriptionBenchmarkFiles.writeProgress(
            phase: "preparing-synthetic-fixtures", to: options.outputDirectory)

        let fixtures = try SyntheticSpeechFixtures(outputDirectory: options.outputDirectory)
        do {
            try await run(fixtures: fixtures)
        } catch {
            let runFailure = error
            do {
                try fixtures.removeGeneratedAudio()
            } catch {
                jlog("Jarvis benchmark: run failed with \(runFailure); fixture cleanup also failed: "
                     + "\(error)")
                throw error
            }
            throw runFailure
        }
        try fixtures.removeGeneratedAudio()
        TranscriptionBenchmarkFiles.writeProgress(
            phase: "complete", detail: "summary.json", to: options.outputDirectory)
        jlog("Jarvis benchmark: complete (\(options.outputDirectory.path)/summary.json)")
    }

    private func run(fixtures: SyntheticSpeechFixtures) async throws {
        guard let first = TranscriptionBenchmark.phrases.first else {
            throw Failure.missingFixture("first")
        }
        try player.prepare(try fixtures.fixture(for: first).fileURL)

        let capture = SystemAudioBenchmarkCapture {
            [relay] data, sequence, samples, timestamp, events in
            relay.enqueue(
                data,
                sequence: sequence,
                samples: samples,
                capturedAt: timestamp,
                speechEvents: events)
        }
        try capture.start()
        defer {
            capture.stop()
            relay.install(nil)
        }

        let summary: TranscriptionBenchmark.Summary
        switch options.mode {
        case .standard:
            summary = try await runStandard(fixtures: fixtures)
        case .reconnect:
            summary = await runReconnect(fixtures: fixtures)
        }
        try TranscriptionBenchmarkFiles.write(
            summary.encodedJSON(),
            named: "summary.json",
            to: options.outputDirectory)
        try validate(summary)
    }

    private func validate(_ summary: TranscriptionBenchmark.Summary) throws {
        switch options.mode {
        case .standard:
            var requiredProviders: Set<TranscriptionProvider> = [.openAI]
            if #available(macOS 26.0, *) {
                requiredProviders.insert(.appleSpeech)
            }
            let incompleteArms = TranscriptionBenchmark.standardAcceptanceFailureArmIDs(
                in: summary,
                expectedRepetitions: options.repetitions,
                requiredProviders: requiredProviders)
            guard incompleteArms.isEmpty else {
                throw Failure.acceptanceFailed(
                    "incomplete standard arms: \(incompleteArms.joined(separator: ", "))")
            }
        case .reconnect:
            var failedModels = summary.reconnect.filter { !$0.passed }.map { $0.model.rawValue }
            if summary.reconnect.count != OpenAITranscriptionModel.allCases.count {
                failedModels.append("missing-model-results")
            }
            guard summary.reconnect.count == OpenAITranscriptionModel.allCases.count,
                  failedModels.isEmpty else {
                throw Failure.acceptanceFailed(
                    "reconnect criteria not met: \(failedModels.joined(separator: ", "))")
            }
        }
    }

    func makeSession(
        arm: TranscriptionBenchmark.Arm,
        appleLocale: Locale?,
        recorder: TranscriptionBenchmarkEventRecorder,
        transportControl: TranscriptionBenchmarkTransportControl? = nil
    ) -> any TranscriptionSession {
        let configuration = TranscriptionConfiguration(
            provider: arm.provider,
            openAIModel: arm.model ?? .gpt4oTranscribe,
            openAILanguageProfile: arm.languageProfile ?? .automatic,
            appleSpeechLocaleIdentifier: arm.localeIdentifier ?? "en_US")
        // Keep production ping/pong timing. The benchmark trips the transport failure path directly;
        // accelerated probes can add a second artificial fault while the provider processes replay.
        let config = Config(
            silenceTimeoutSeconds: 120,
            silenceMaxIntervalSeconds: 960,
            silenceIdleCutoffSeconds: 1_800,
            historyCompactionTokenThreshold: 10_000,
            overlayNoticeBufferSeconds: 2,
            overlaySecondsPerWord: 0.35,
            overlayMaxDisplaySeconds: 8,
            vadSilenceDurationMs: 1_000,
            audioNoiseReduction: .off,
            turnDebounceSeconds: 0,
            maxBufferedAudioSeconds: 120,
            realtimeReadyTimeoutSeconds: 15)
        let session = TranscriptionSessionFactory.make(
            configuration: configuration,
            apiKey: apiKey ?? "",
            appleSpeechLocale: appleLocale,
            speaker: .them,
            transcript: RollingTranscript(),
            clock: clock,
            config: config,
            networkStatus: { [networkDiagnostics] in
                networkDiagnostics.currentSummary
            },
            benchmark: .init(
                observer: recorder,
                transportControl: transportControl))
        session.onConnectionStateChange = { [recorder] in recorder.record($0) }
        session.onTerminalFailure = { [recorder] in recorder.record($0) }
        return session
    }
}
