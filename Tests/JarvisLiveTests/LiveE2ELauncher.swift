import Foundation
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import Testing

/// Launches only with the handshake variables `scripts/run-live-tests.sh` sets, so a direct
/// `swift test` never reaches a provider.
struct LiveE2ELauncher {
    let scenarioID: String
    let scenarioData: Data
    let scenario: LiveE2EScenario
    let runDirectory: URL
    let app: URL
    let keepGoing: Bool

    var directory: URL { runDirectory.appendingPathComponent(scenarioID, isDirectory: true) }

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixturesDirectory = repository
        .appendingPathComponent("Tests/JarvisLiveTests/Fixtures", isDirectory: true)
    static let scenariosDirectory = repository
        .appendingPathComponent("Tests/JarvisLiveTests/Scenarios", isDirectory: true)
    private static let stopMarker = "stop-after-failure"
    private static let launchTimeout: TimeInterval = 22 * 60

    /// Nil when the scenario must not launch; the issue or skipped line is already recorded.
    static func begin(
        scenario scenarioID: String, file: String? = nil,
        transcriptionTarget: TranscriptionTarget? = nil
    ) async -> LiveE2ELauncher? {
        let environment = ProcessInfo.processInfo.environment
        guard let run = environment["JARVIS_LIVE_E2E_RUN_DIR"],
              let app = environment["JARVIS_LIVE_E2E_APP"] else {
            Issue.record("Run the live e2e tests through scripts/run-live-tests.sh.")
            return nil
        }
        let runDirectory = URL(fileURLWithPath: run, isDirectory: true)
        let keepGoing = environment["JARVIS_LIVE_E2E_KEEP_GOING"] == "1"
        if !keepGoing,
           FileManager.default.fileExists(atPath: runDirectory.appendingPathComponent(stopMarker).path) {
            var results = LiveE2EResults(scenario: scenarioID)
            results.skipped(scenarioID, "an earlier scenario failed; rerun with --keep-going to run it")
            try? write(results, to: runDirectory.appendingPathComponent(scenarioID, isDirectory: true))
            return nil
        }
        let scenario: LiveE2EScenario
        let scenarioData: Data
        do {
            let source = try Data(contentsOf:
                scenariosDirectory.appendingPathComponent("\(file ?? scenarioID).json"))
            let transcriptionData: Data
            if let target = transcriptionTarget {
                guard var json = try JSONSerialization.jsonObject(with: source) as? [String: Any],
                      var transcription = json["transcription"] as? [String: Any] else {
                    throw LiveE2EScenario.Failure.invalid("missing transcription settings")
                }
                transcription["provider"] = target.provider.rawValue
                transcription["model"] = target.modelID
                transcription["locale"] = target.localeIdentifier
                json["transcription"] = transcription
                json["id"] = scenarioID
                transcriptionData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            } else {
                transcriptionData = source
            }
            let selection = environment["JARVIS_LIVE_E2E_PROVIDER"] ?? BrainProvider.codexSubscription.rawValue
            if selection == "scenario" {
                scenarioData = transcriptionData
            } else if let provider = BrainProvider(rawValue: selection) {
                scenarioData = try LiveE2EScenario.selectingProvider(
                    provider, in: transcriptionData, fixturesDirectory: fixturesDirectory)
            } else {
                throw LiveE2EScenario.Failure.invalid("unknown provider selection \"\(selection)\"")
            }
            scenario = try LiveE2EScenario.decode(scenarioData, fixturesDirectory: fixturesDirectory)
        } catch {
            Issue.record(error)
            return nil
        }
        if let failure = LiveE2EPreflight.failure(for: scenario) {
            Issue.record(Comment(rawValue: failure))
            return nil
        }
        return LiveE2ELauncher(
            scenarioID: scenarioID, scenarioData: scenarioData, scenario: scenario,
            runDirectory: runDirectory, app: URL(fileURLWithPath: app, isDirectory: true),
            keepGoing: keepGoing)
    }

    /// A throwing launch never reaches `finish`, so it kills the app and stops later scenarios
    /// itself.
    func launch(secretsDirectory: URL? = nil) async throws -> LiveE2ELaunch {
        do {
            return try await launchAndWait(secretsDirectory: secretsDirectory)
        } catch {
            Self.stopOwnedApp()
            stopLaterScenarios()
            throw error
        }
    }

    func finish(_ results: LiveE2EResults) throws {
        if results.hasFailure { stopLaterScenarios() }
        try Self.write(results, to: directory)
    }

    private func stopLaterScenarios() {
        guard !keepGoing else { return }
        FileManager.default.createFile(
            atPath: runDirectory.appendingPathComponent(Self.stopMarker).path, contents: nil)
    }

    private func launchAndWait(secretsDirectory: URL?) async throws -> LiveE2ELaunch {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let scenarioCopy = directory.appendingPathComponent("scenario.json")
        try scenarioData.write(to: scenarioCopy)

        var arguments = [
            Self.repository.appendingPathComponent("scripts/test-display/supervisor.py").path,
            "launch-app", app.path, "--args",
            "--live-e2e",
            "--live-e2e-scenario", scenarioCopy.path,
            "--live-e2e-output-dir", directory.path,
            "--live-e2e-repo-dir", Self.repository.path,
            "--live-e2e-fixtures-dir", Self.fixturesDirectory.path,
        ]
        if let secretsDirectory { arguments += ["--live-e2e-secrets-dir", secretsDirectory.path] }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JARVIS_TEST_PYTHON"] ?? "/usr/bin/python3")
        opener.arguments = arguments
        try TestCommandOwnership.launchChild(opener)

        let deadline = Date().addingTimeInterval(Self.launchTimeout)
        var abortDeadline: Date?
        var timedOut = false
        while opener.isRunning {
            if abortDeadline == nil, Date() > deadline {
                timedOut = true
                fileManager.createFile(
                    atPath: directory.appendingPathComponent("abort").path, contents: nil)
                abortDeadline = Date().addingTimeInterval(10)
            }
            if let abortDeadline, Date() > abortDeadline {
                Self.stopOwnedApp()
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        guard !opener.isRunning, opener.terminationReason == .exit, opener.terminationStatus == 0 else {
            throw NSError(domain: "LiveE2ELauncher", code: 70, userInfo: [NSLocalizedDescriptionKey:
                "The supervised launcher did not complete app/helper teardown"])
        }

        let sessionRoot = directory.appendingPathComponent("session", isDirectory: true)
        let sessions = ((try? fileManager.contentsOfDirectory(
            at: sessionRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let sessionDirectory = sessions.count == 1 ? sessions[0] : nil
        return LiveE2ELaunch(
            scenario: scenario,
            directory: directory,
            finished: fileManager.fileExists(
                atPath: directory.appendingPathComponent("live-e2e-finished").path),
            failure: timedOut ? "timed out after \(Int(Self.launchTimeout))s" : Self.recordedFailure(in: directory),
            sessionCount: sessions.count,
            sessionDirectory: sessionDirectory,
            evidence: try sessionDirectory.map { try LiveSessionEvidence(sessionDirectory: $0) },
            stepAttempts: Self.stepAttempts(in: directory),
            leftoverHelperIDs: [])
    }

    func makeInvalidKeyDirectory() throws -> URL {
        let secrets = runDirectory.appendingPathComponent("\(scenarioID)-secrets", isDirectory: true)
        return try scenario.makeInvalidKeyDirectory(at: secrets)
    }

    // MARK: - Helpers

    private static func write(_ results: LiveE2EResults, to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = results.lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: directory.appendingPathComponent("results.txt"))
    }

    private static func recordedFailure(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("live-e2e-error.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let step = (object["step"] as? Int).map { " at step \($0)" } ?? ""
        return "\(object["error"] as? String ?? "unknown error")\(step)"
    }

    private static func stepAttempts(in directory: URL) -> [Int: Int] {
        guard let text = try? String(
            contentsOf: directory.appendingPathComponent("steps.jsonl"), encoding: .utf8) else {
            return [:]
        }
        var map: [Int: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let step = object["step"] as? Int, let attempt = object["attempt"] as? Int else {
                continue
            }
            map[step] = attempt
        }
        return map
    }

    private static func stopOwnedApp() {
        run(ProcessInfo.processInfo.environment["JARVIS_TEST_PYTHON"] ?? "/usr/bin/python3",
            [repository.appendingPathComponent("scripts/test-display/supervisor.py").path, "stop-app"])
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct LiveE2ELaunch {
    let scenario: LiveE2EScenario
    let directory: URL
    let finished: Bool
    let failure: String?
    let sessionCount: Int
    let sessionDirectory: URL?
    let evidence: LiveSessionEvidence?
    /// Step index to attempt id.
    let stepAttempts: [Int: Int]
    let leftoverHelperIDs: [Int32]

    func stepIndices(_ isIncluded: (LiveE2EScenario.Step) -> Bool) -> [Int] {
        scenario.steps.indices.filter { isIncluded(scenario.steps[$0]) }
    }

    func attempt(forStep step: Int?) -> LiveSessionEvidence.Attempt? {
        guard let step, let id = stepAttempts[step] else { return nil }
        return evidence?.attempt(id: id)
    }

    /// Empty when the step matched no attempt.
    func attemptChain(forStep step: Int?) -> [LiveSessionEvidence.Attempt] {
        guard let first = attempt(forStep: step), let evidence else { return [] }
        return evidence.retryChain(from: first)
    }
}

/// Reads only the selected scenario's credentials and account files; never starts a second helper.
enum LiveE2EPreflight {
    static func failure(for scenario: LiveE2EScenario) -> String? {
        // LaunchServices does not pass this shell's environment, so only the key file serves the
        // run.
        for credential in Credential.allCases
        where scenario.requiredCredentials.contains(credential)
            && FileSecretStore().apiKey(for: credential)?.isEmpty != false {
            return "No \(credential.displayName) key in Jarvis's key file: save one in Jarvis Settings → Connections. "
                + "\(credential.environmentVariable) does not reach an app launched with open."
        }
        let auth = FileSecretStore().directoryURL
            .appendingPathComponent("proxy/auth", isDirectory: true)
        for provider in BrainProvider.allCases
        where scenario.requiredBrainProviders.contains(provider) && provider.servedByLocalProxy
            && LocalProxyAccountFile.all(in: auth, for: provider).isEmpty {
            return "\(provider.displayName) is not signed in: sign in from Jarvis Dev Settings → Connections."
        }
        return nil
    }
}
