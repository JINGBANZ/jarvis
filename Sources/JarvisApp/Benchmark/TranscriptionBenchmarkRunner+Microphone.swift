import Foundation
import JarvisCore

extension TranscriptionBenchmarkRunner {
    func runMicrophone() async throws {
        guard apiKey != nil else { throw Failure.apiKeyUnavailable }
        networkDiagnostics.start()
        try TranscriptionBenchmarkFiles.write(
            JSONEncoder().encode(MicrophoneBenchmark.phrases), named: "script.json", to: options.outputDirectory)
        var results: [MicrophoneBenchmark.Result] = []
        var trial = 0
        for repetition in 1...options.repetitions {
            for phrase in MicrophoneBenchmark.phrases {
                trial += 1
                TranscriptionBenchmarkFiles.writeProgress(
                    phase: "waiting-for-start", detail: String(trial), to: options.outputDirectory)
                try await waitForMicrophoneMarker("start-\(trial)", timeout: 600)
                let pair = try await runMicrophonePair(phrase: phrase, repetition: repetition, trial: trial)
                results.append(contentsOf: pair)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try TranscriptionBenchmarkFiles.write(
                    encoder.encode(MicrophoneBenchmark.Summary(results: results)),
                    named: "summary.json", to: options.outputDirectory)
                guard pair.allSatisfy(\.usable) else {
                    throw Failure.acceptanceFailed("Microphone pair incomplete")
                }
            }
        }
        TranscriptionBenchmarkFiles.writeProgress(phase: "complete", to: options.outputDirectory)
    }

    private func runMicrophonePair(
        phrase: TranscriptionBenchmark.Phrase, repetition: Int, trial: Int
    ) async throws -> [MicrophoneBenchmark.Result] {
        let arms = MicrophoneBenchmark.arms(for: phrase)
        let recorders = arms.map { _ in TranscriptionBenchmarkEventRecorder(abortMarker: abortMarker) }
        let sessions = zip(arms, recorders).map { makeSession(arm: $0, appleLocale: nil, recorder: $1) }
        let relays = arms.map { _ in TranscriptionBenchmarkSessionRelay() }
        for index in arms.indices {
            let recorder = recorders[index]
            relays[index].install(sessions[index]) { sequence, samples in
                recorder.recordCapture(sequence: sequence, samples: samples)
            }
        }
        let capture = MicrophoneBenchmarkCapture { data, sequence, samples, timestamp, events in
            for relay in relays {
                relay.enqueue(data, sequence: sequence, samples: samples,
                              capturedAt: timestamp, speechEvents: events)
            }
        }
        defer {
            capture.stop()
            for relay in relays { relay.install(nil) }
            for session in sessions { session.stop() }
        }
        for index in (trial.isMultiple(of: 2) ? Array(arms.indices.reversed()) : Array(arms.indices)) {
            sessions[index].connect()
        }
        for recorder in recorders { _ = try await recorder.waitForReady(timeout: 20) }
        try await capture.start()
        TranscriptionBenchmarkFiles.writeProgress(
            phase: "recording", detail: String(trial), to: options.outputDirectory)
        var failed = false
        do {
            try await waitForMicrophoneMarker("finish-\(trial)", timeout: 45)
            // Let the local detector observe trailing silence before releasing the microphone.
            try await Task.sleep(for: .seconds(2))
            capture.stop()
            for relay in relays { relay.install(nil) }
            for recorder in recorders {
                try await recorder.waitForFinalStreamToSettle(minimumCount: 1, quietPeriod: 5, timeout: 20)
            }
        } catch {
            failed = true
        }
        capture.stop()
        for relay in relays { relay.install(nil) }
        for session in sessions { session.stop() }
        return arms.indices.map { index in
            let snapshot = recorders[index].snapshot()
            return MicrophoneBenchmark.score(
                arm: arms[index], repetition: repetition, events: snapshot.events,
                capture: snapshot.captureObservations, states: snapshot.states,
                droppedChunks: capture.droppedChunkCount,
                failed: failed || snapshot.terminalFailure != nil)
        }
    }

    private func waitForMicrophoneMarker(_ name: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let marker = options.outputDirectory.appendingPathComponent(name)
        while !FileManager.default.fileExists(atPath: marker.path) {
            try Task.checkCancellation()
            guard !isAbortRequested else { throw Failure.benchmarkAborted }
            guard Date() < deadline else { throw Failure.acceptanceFailed("Microphone control timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard !isAbortRequested else { throw Failure.benchmarkAborted }
    }
}
