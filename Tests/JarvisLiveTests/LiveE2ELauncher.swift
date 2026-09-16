import Foundation
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import Testing

/// Launches the signed development app in its live e2e mode for one scenario file and hands back
/// what the session left.
///
/// Only `scripts/run-live-tests.sh` supplies the handshake variables: the run directory it created
/// and the app it just built. Without them nothing launches, so the target cannot reach a provider
/// by accident when someone runs `swift test` directly.
struct LiveE2ELauncher {
    let scenarioID: String
    let scenarioFile: String
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
    /// Written by `finish` when a scenario failed, so later scenarios skip unless `--keep-going`.
    private static let stopMarker = "stop-after-failure"
    private static let appProcessPattern = "/Jarvis Dev[.]app/Contents/MacOS/JarvisApp"
    private static let launchTimeout: TimeInterval = 22 * 60

    /// The subscription helper bundled in this app, the one child a session may leave running.
    private var helperProcessPattern: String {
        NSRegularExpression.escapedPattern(
            for: app.appendingPathComponent("Contents/MacOS/cliproxyapi").path)
    }

    /// Everything a scenario test needs before launching, or nil when it must not launch: the
    /// script's handshake or the preflight is missing (an issue is recorded), or an earlier scenario
    /// failed without `--keep-going` (a skipped line is written).
    static func begin(scenario scenarioID: String, file: String? = nil) async -> LiveE2ELauncher? {
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
        if let failure = LiveE2EPreflight.failure {
            Issue.record(Comment(rawValue: failure))
            return nil
        }
        return LiveE2ELauncher(
            scenarioID: scenarioID, scenarioFile: file ?? scenarioID,
            runDirectory: runDirectory, app: URL(fileURLWithPath: app, isDirectory: true),
            keepGoing: keepGoing)
    }

    /// Launch the app on this scenario and wait for it to exit. On timeout the app is asked to abort,
    /// then killed. A launch that throws never reaches `finish`, so it kills the app and stops later
    /// scenarios itself before rethrowing.
    func launch(secretsDirectory: URL? = nil) async throws -> LiveE2ELaunch {
        do {
            return try await launchAndWait(secretsDirectory: secretsDirectory)
        } catch {
            Self.run("/usr/bin/pkill", ["-f", Self.appProcessPattern])
            stopLaterScenarios()
            throw error
        }
    }

    /// Write this scenario's results lines, and stop later scenarios after a failure unless the run
    /// keeps going.
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
        let source = Self.scenariosDirectory.appendingPathComponent("\(scenarioFile).json")
        let scenario = try LiveE2EScenario.load(from: source, fixturesDirectory: Self.fixturesDirectory)
        let scenarioCopy = directory.appendingPathComponent("scenario.json")
        try fileManager.copyItem(at: source, to: scenarioCopy)

        let processesBefore = Self.processIDs(matching: helperProcessPattern)
        var arguments = [
            "-W", "-n", app.path, "--args",
            "--live-e2e",
            "--live-e2e-scenario", scenarioCopy.path,
            "--live-e2e-output-dir", directory.path,
            "--live-e2e-repo-dir", Self.repository.path,
            "--live-e2e-fixtures-dir", Self.fixturesDirectory.path,
        ]
        if let secretsDirectory { arguments += ["--live-e2e-secrets-dir", secretsDirectory.path] }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = arguments
        try opener.run()

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
                Self.run("/usr/bin/pkill", ["-f", Self.appProcessPattern])
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        // The app signals its helper as it exits; give the helper a moment before calling it leftover.
        var leftovers = Self.processIDs(matching: helperProcessPattern).subtracting(processesBefore)
        for _ in 0..<25 where !leftovers.isEmpty {
            try await Task.sleep(for: .milliseconds(200))
            leftovers = Self.processIDs(matching: helperProcessPattern).subtracting(processesBefore)
        }
        // A forced teardown killed the app before it could signal its helper, so this run owns what
        // survives. G08 still reports the leftover and still fails, but the process does not outlive
        // the run, and `--keep-going` cannot hide it inside the next scenario's baseline.
        if timedOut, !leftovers.isEmpty {
            Self.run("/bin/kill", leftovers.sorted().map(String.init))
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
            leftoverHelperIDs: leftovers.sorted())
    }

    /// A run-local secrets directory holding an obviously invalid OpenAI key, for F02.
    func makeInvalidKeyDirectory() throws -> URL {
        let secrets = runDirectory.appendingPathComponent("\(scenarioID)-secrets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: secrets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileSecretStore(directoryURL: secrets)
            .setApiKey("sk-jarvis-live-e2e-invalid-key", for: .openAIAPIKey) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return secrets
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

    private static func processIDs(matching pattern: String) -> Set<Int32> {
        let output = run("/usr/bin/pgrep", ["-f", pattern])
        return Set(output.split(separator: "\n").compactMap { Int32($0) })
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

/// What one scenario launch left behind.
struct LiveE2ELaunch {
    let scenario: LiveE2EScenario
    let directory: URL
    let finished: Bool
    let failure: String?
    let sessionCount: Int
    let sessionDirectory: URL?
    let evidence: LiveSessionEvidence?
    /// Step index to attempt id, from the runner's `steps.jsonl`.
    let stepAttempts: [Int: Int]
    /// Subscription helpers from this app still running after it exited.
    let leftoverHelperIDs: [Int32]

    func stepIndices(_ isIncluded: (LiveE2EScenario.Step) -> Bool) -> [Int] {
        scenario.steps.indices.filter { isIncluded(scenario.steps[$0]) }
    }

    func attempt(forStep step: Int?) -> LiveSessionEvidence.Attempt? {
        guard let step, let id = stepAttempts[step] else { return nil }
        return evidence?.attempt(id: id)
    }

    /// The step's attempt followed by the retries its provider stalls caused; empty when the step
    /// matched no attempt. A step's cases are judged on this chain and its last attempt.
    func attemptChain(forStep step: Int?) -> [LiveSessionEvidence.Attempt] {
        guard let first = attempt(forStep: step), let evidence else { return [] }
        return evidence.retryChain(from: first)
    }
}

/// The run's one preflight: the OpenAI key resolves and both subscriptions hold a saved sign-in.
/// It reads files only, so it never starts a second helper beside the one the app runs.
enum LiveE2EPreflight {
    static let failure: String? = {
        // The app is launched through LaunchServices, which does not hand it this shell's
        // environment, so only the owner-only key file can serve the run.
        guard FileSecretStore().apiKey(for: .openAIAPIKey)?.isEmpty == false else {
            return "No OpenAI API key in Jarvis's key file: save one in Jarvis Settings → Connections. "
                + "OPENAI_API_KEY does not reach an app launched with open."
        }
        let auth = FileSecretStore().directoryURL
            .appendingPathComponent("proxy/auth", isDirectory: true)
        for provider in [BrainProvider.codexSubscription, .claudeSubscription]
        where LocalProxyAccountFile.all(in: auth, for: provider).isEmpty {
            return "\(provider.displayName) is not signed in: sign in from Jarvis Dev Settings → Connections."
        }
        return nil
    }()
}
