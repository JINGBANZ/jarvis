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
            case .benchmarkAborted: "Reconnect benchmark aborted"
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
        defer { fixtures.removeGeneratedAudio() }
        guard let first = TranscriptionBenchmark.phrases.first else {
            throw Failure.missingFixture("first")
        }
        try player.prepare(try fixtures.fixture(for: first).fileURL)

        let capture = SystemAudioBenchmarkCapture {
            [relay] data, sequence, samples, timestamp, events in
            relay.deliver(
                data,
                sequence: sequence,
                samples: samples,
                capturedAt: timestamp,
                speechEvents: events)
        }
        try capture.start()
        defer {
            relay.install(nil)
            capture.stop()
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
        TranscriptionBenchmarkFiles.writeProgress(
            phase: "complete", detail: "summary.json", to: options.outputDirectory)
        jlog("Jarvis benchmark: complete (\(options.outputDirectory.path)/summary.json)")
    }

    private func validate(_ summary: TranscriptionBenchmark.Summary) throws {
        switch options.mode {
        case .standard:
            let incompleteArms = summary.arms.compactMap { arm -> String? in
                if arm.unavailableReason != nil { return arm.arm.id }
                guard arm.repetitions.count == options.repetitions,
                      arm.repetitions.allSatisfy({ $0.failure == nil && $0.continuityPassed }) else {
                    return arm.arm.id
                }
                return nil
            }
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
        reconnectTiming: Bool = false
    ) -> any TranscriptionSession {
        let configuration = TranscriptionConfiguration(
            provider: arm.provider,
            openAIModel: arm.model ?? .gpt4oTranscribe,
            openAILanguageProfile: arm.languageProfile ?? .automatic,
            appleSpeechLocaleIdentifier: arm.localeIdentifier ?? "en_US")
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
            realtimeReadyTimeoutSeconds: 15,
            realtimePingIntervalSeconds: reconnectTiming ? 2 : 20,
            realtimePongTimeoutSeconds: reconnectTiming ? 2 : 10)
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
            })
        session.onConnectionStateChange = { [recorder] in recorder.record($0) }
        session.onTerminalFailure = { [recorder] in recorder.record($0) }
        session.onDiagnosticEvent = { [recorder] in recorder.record($0) }
        return session
    }
}
