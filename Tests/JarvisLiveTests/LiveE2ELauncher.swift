import Foundation
import JarvisBrainProviders
import JarvisCore
import JarvisEvaluation
import Testing

/// Launches the signed development app in its live e2e mode for one scenario file, serves the
/// app's screen requests, and hands back what the session left.
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
    let clis: [BrainProvider: DetectedAgentCLI]

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
    /// The Codex app-server and the Claude warm query, the two CLI children a session may start.
    private static let cliChildPattern = "app-server|--output-format stream-json"
    private static let launchTimeout: TimeInterval = 22 * 60

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
        switch await LiveE2EPreflight.shared.result() {
        case .failure(let failure):
            Issue.record(Comment(rawValue: failure.message))
            return nil
        case .success(let clis):
            return LiveE2ELauncher(
                scenarioID: scenarioID, scenarioFile: file ?? scenarioID,
                runDirectory: runDirectory, app: URL(fileURLWithPath: app, isDirectory: true),
                keepGoing: keepGoing, clis: clis)
        }
    }

    /// Launch the app on this scenario and wait for it to exit, opening fixture windows whenever the
    /// app asks. On timeout the app is asked to abort, then killed.
    func launch(secretsDirectory: URL? = nil, claudeCLI: URL? = nil) async throws -> LiveE2ELaunch {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = Self.scenariosDirectory.appendingPathComponent("\(scenarioFile).json")
        let scenario = try LiveE2EScenario.load(from: source, fixturesDirectory: Self.fixturesDirectory)
        let scenarioCopy = directory.appendingPathComponent("scenario.json")
        try fileManager.copyItem(at: source, to: scenarioCopy)

        let processesBefore = Self.processIDs(matching: Self.cliChildPattern)
        let runtimeHomesBefore = Self.codexRuntimeHomes()
        var arguments = [
            "-W", "-n", app.path, "--args",
            "--live-e2e",
            "--live-e2e-scenario", scenarioCopy.path,
            "--live-e2e-output-dir", directory.path,
            "--live-e2e-repo-dir", Self.repository.path,
            "--live-e2e-fixtures-dir", Self.fixturesDirectory.path,
        ]
        if let secretsDirectory { arguments += ["--live-e2e-secrets-dir", secretsDirectory.path] }
        if let claudeCLI { arguments += ["--live-e2e-cli-claude", claudeCLI.path] }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = arguments
        try opener.run()

        let deadline = Date().addingTimeInterval(Self.launchTimeout)
        var abortDeadline: Date?
        var timedOut = false
        while opener.isRunning {
            try await serveScreenRequest()
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

        // CLI children exit once their parent is gone; give them a moment before calling one leftover.
        var leftovers = Self.processIDs(matching: Self.cliChildPattern).subtracting(processesBefore)
        for _ in 0..<25 where !leftovers.isEmpty {
            try await Task.sleep(for: .milliseconds(200))
            leftovers = Self.processIDs(matching: Self.cliChildPattern).subtracting(processesBefore)
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
            leftoverProcessIDs: leftovers.sorted(),
            leftoverRuntimeHomes: Self.codexRuntimeHomes().subtracting(runtimeHomesBefore).sorted())
    }

    /// Write this scenario's results lines, and stop later scenarios after a failure unless the run
    /// keeps going.
    func finish(_ results: LiveE2EResults) throws {
        try Self.write(results, to: directory)
        if results.hasFailure, !keepGoing {
            FileManager.default.createFile(
                atPath: runDirectory.appendingPathComponent(Self.stopMarker).path, contents: nil)
        }
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

    /// A Claude Code stand-in that exits at once until the runner's `claude-restored` marker exists,
    /// then hands every launch to the real CLI. The app treats every local-agent process failure as
    /// temporary, which is the failure F04 needs; an invalid key would be permanent.
    func makeClaudeStub() throws -> URL {
        guard let real = clis[.claudeCode]?.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let stub = runDirectory.appendingPathComponent("\(scenarioID)-claude-stub")
        let marker = directory.appendingPathComponent("claude-restored")
        let script = """
        #!/bin/sh
        [ -f '\(marker.path)' ] && exec '\(real.path)' "$@"
        exit 1

        """
        guard FileManager.default.createFile(
            atPath: stub.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
        else { throw CocoaError(.fileWriteUnknown) }
        return stub
    }

    // MARK: - Helpers

    /// The app may not open apps, so it asks on a file and this process opens the fixture: Preview
    /// for images, TextEdit for text. The pause lets the new window reach the front before answering.
    private func serveScreenRequest() async throws {
        let request = directory.appendingPathComponent("screen-request.json")
        let ready = directory.appendingPathComponent("screen-ready")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: request.path), !fileManager.fileExists(atPath: ready.path),
              let data = try? Data(contentsOf: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fixture = object["fixture"] as? String else { return }
        let url = Self.fixturesDirectory.appendingPathComponent(fixture)
        let application = url.pathExtension == "txt" ? "TextEdit" : "Preview"
        Self.run("/usr/bin/open", ["-a", application, url.path])
        try await Task.sleep(for: .seconds(2))
        fileManager.createFile(atPath: ready.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

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

    /// Session-scoped Codex homes the app creates under Application Support and removes on Stop.
    private static func codexRuntimeHomes() -> Set<String> {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis/agent-runtimes", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return Set(names.filter { $0.hasPrefix("codex-runtime-") })
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
    let leftoverProcessIDs: [Int32]
    let leftoverRuntimeHomes: [String]

    func stepIndices(_ isIncluded: (LiveE2EScenario.Step) -> Bool) -> [Int] {
        scenario.steps.indices.filter { isIncluded(scenario.steps[$0]) }
    }

    func attempt(forStep step: Int?) -> LiveSessionEvidence.Attempt? {
        guard let step, let id = stepAttempts[step] else { return nil }
        return evidence?.attempt(id: id)
    }
}

/// The run's one preflight: the OpenAI key resolves and both CLI brains are signed in. Run once and
/// remembered, so seven launches do not repeat CLI detection.
actor LiveE2EPreflight {
    struct Failure: Error {
        let message: String
    }

    static let shared = LiveE2EPreflight()
    private var cached: Result<[BrainProvider: DetectedAgentCLI], Failure>?

    func result() async -> Result<[BrainProvider: DetectedAgentCLI], Failure> {
        if let cached { return cached }
        let computed = await compute()
        cached = computed
        return computed
    }

    private func compute() async -> Result<[BrainProvider: DetectedAgentCLI], Failure> {
        // The app is launched through LaunchServices, which does not hand it this shell's
        // environment, so only the owner-only key file can serve the run.
        guard FileSecretStore().apiKey(for: .openAIAPIKey)?.isEmpty == false else {
            return .failure(Failure(message:
                "No OpenAI API key in Jarvis's key file: save one in Jarvis Settings → Connections. "
                    + "OPENAI_API_KEY does not reach an app launched with open."))
        }
        let detected = await AgentCLIDetector().detectAllAsync([.claudeCode, .codexCLI])
        let clis = Dictionary(uniqueKeysWithValues: detected.map { ($0.provider, $0) })
        for provider in [BrainProvider.claudeCode, .codexCLI] {
            guard let cli = clis[provider] else {
                return .failure(Failure(message: "\(provider.displayName) CLI was not found."))
            }
            guard cli.authenticationStatus == .signedIn else {
                return .failure(Failure(message: "\(provider.displayName) is not signed in."))
            }
        }
        return .success(clis)
    }
}
