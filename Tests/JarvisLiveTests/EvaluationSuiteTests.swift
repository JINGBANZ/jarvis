import Foundation
import CryptoKit
import JarvisCore
import JarvisBrainProviders
import JarvisEvaluation
import JarvisTestSupport
import Testing

@Suite(.serialized)
struct EvaluationSuiteTests {
    @Test func selectedSuite() async throws {
        do { try await runSelectedSuite() }
        catch {
            let environment = ProcessInfo.processInfo.environment
            if let path = environment["JARVIS_LIVE_E2E_RUN_DIR"] {
                try EvaluationSuiteReport(suite: environment["JARVIS_EVALUATION_SUITE"] ?? "unknown",
                    results: [], runErrors: [ProviderMessageRedaction.redact(error.localizedDescription)])
                    .write(to: URL(fileURLWithPath: path))
            }
            throw error
        }
    }

    private func runSelectedSuite() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let suite = environment["JARVIS_EVALUATION_SUITE"],
              let path = environment["JARVIS_LIVE_E2E_RUN_DIR"],
              let repeats = Int(environment["JARVIS_EVALUATION_REPEAT"] ?? ""), repeats > 0,
              let provider = BrainProvider(rawValue: environment["JARVIS_LIVE_E2E_PROVIDER"] ?? "") else {
            Issue.record("Use scripts/run-live-tests.sh --suite coaching/intervention or app/coaching")
            return
        }
        let root = URL(fileURLWithPath: path)
        let suiteCatalog = try EvaluationSuiteCatalog.load(from: LiveE2ELauncher.scenariosDirectory.appendingPathComponent("evaluation-suites.json"))
        let selected = try #require(suiteCatalog.suites.first { $0.id == suite })
        if selected.executor == .signedApp {
            for index in 1...repeats {
                let layout = SignedAppEvaluationRun(runDirectory: root, repeatIndex: index)
                let directory = layout.reportDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let launcher = try #require(await LiveE2ELauncher.begin(scenario: layout.scenarioID,
                    file: selected.scenario, keepGoing: true))
                try await LiveE2ETests.checkScenarioA(launcher: launcher)
                let raw = try String(contentsOf: launcher.directory.appendingPathComponent("results.txt"), encoding: .utf8)
                let lines = raw.split(separator: "\n")
                let checks = lines.filter { $0.split(separator: " ").dropFirst().first == "pass" || $0.split(separator: " ").dropFirst().first == "fail" }
                let finished = FileManager.default.fileExists(atPath: launcher.directory.appendingPathComponent("live-e2e-finished").path)
                let passed = finished && !checks.isEmpty && !checks.contains { $0.split(separator: " ").dropFirst().first == "fail" }
                let results = checks.map { line in
                    let fields = line.split(separator: " ")
                    return EvaluationDecisionResult(id: String(fields[0]), expectation: .eitherAcceptable,
                        evidence: .init(completed: finished, outcome: String(line), replies: [], assertionsPassed: fields[1] == "pass"), verdict: nil)
                }
                try EvaluationSuiteReport(suite: suite, results: results, metadata: ["adapter": "signed-app", "provider": provider.rawValue, "acceptance": selected.acceptance,
                    "rawEvidenceDirectory": launcher.directory.path,
                    "sourceRevision": environment["JARVIS_EVALUATION_SOURCE_REVISION"] ?? "unknown", "sourceSHA256": try sourceFingerprint()]).write(to: directory)
                #expect(passed)
            }
            return
        }
        let catalogURL = LiveE2ELauncher.scenariosDirectory.appendingPathComponent(try #require(selected.catalog))
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try CoachingReplayCatalog.load(from: catalogURL)
        let target = BrainTarget(provider: provider, modelID: environment["JARVIS_EVALUATION_MODEL"] ?? BrainModelCatalog.defaultModel(for: provider).id)
        let judgeProvider = try #require(BrainProvider(rawValue: environment["JARVIS_EVALUATION_JUDGE_PROVIDER"] ?? provider.rawValue), "Invalid judge provider")
        let judgeTarget = BrainTarget(provider: judgeProvider, modelID: environment["JARVIS_EVALUATION_JUDGE_MODEL"] ?? BrainModelCatalog.defaultModel(for: judgeProvider).id)
        let effort = try #require(ReasoningEffort(rawValue: environment["JARVIS_EVALUATION_EFFORT"] ?? Defaults.Brain.effort.rawValue), "Invalid coach reasoning effort")
        let judgeEffort = try #require(ReasoningEffort(rawValue: environment["JARVIS_EVALUATION_JUDGE_EFFORT"] ?? ReasoningEffort.low.rawValue), "Invalid judge reasoning effort")
        let needsProxy = provider.servedByLocalProxy || judgeProvider.servedByLocalProxy
        let proxy = LocalProxySupervisor(executable: LocalProxySupervisor.bundledExecutable(),
            home: FileSecretStore().directoryURL.appendingPathComponent("proxy"), launcher: TestCommandOwnership.makeLauncher())
        let readiness = needsProxy ? await proxy.readiness() : nil
        if needsProxy {
            for target in [target, judgeTarget] where target.provider.servedByLocalProxy {
                if let failure = readiness?.unavailability(for: target) { await proxy.stop(); throw failure }
            }
        }
        do {
            let secrets = ChainedSecretStore([FileSecretStore(), EnvSecretStore()])
            let keys = Dictionary(uniqueKeysWithValues: Credential.allCases.compactMap { key in secrets.apiKey(for: key).map { (key, $0) } })
            for target in [target, judgeTarget] {
                if case .apiKey(let credential, _, _) = target.provider.descriptor.access, keys[credential] == nil {
                    throw NSError(domain: "evaluation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(credential.displayName)"])
                }
            }
            let metadata = ["coachProvider": provider.rawValue, "coachModel": target.modelID,
                "coachEffort": effort.rawValue, "judgeProvider": judgeProvider.rawValue,
                "judgeModel": judgeTarget.modelID, "judgeEffort": judgeEffort.rawValue,
                "rubricVersion": catalog.rubricVersion, "catalogVersion": catalog.version,
                "catalogSHA256": SHA256.hash(data: catalogData).map { String(format: "%02x", $0) }.joined(),
                "sourceRevision": environment["JARVIS_EVALUATION_SOURCE_REVISION"] ?? "unknown",
                "config": "Config.default", "saveConversations": "false", "acceptance": selected.acceptance,
                "sourceDirtyFiles": environment["JARVIS_EVALUATION_SOURCE_DIRTY"] ?? "unknown",
                "sourceSHA256": try sourceFingerprint()]
            for index in 1...repeats {
                let directory = root.appendingPathComponent("repeat-\(index)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try catalogData.write(to: directory.appendingPathComponent("catalog.json"))
                let coachDirectory = directory.appendingPathComponent("coach-wire")
                let judgeDirectory = directory.appendingPathComponent("judge-wire")
                for folder in [coachDirectory, judgeDirectory] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                let coachAudit = FileSessionAudit(directory: coachDirectory)
                let judgeAudit = FileSessionAudit(directory: judgeDirectory)
                let coachFactory = BrainClientFactory(keys: keys, proxyEndpoint: readiness?.endpoint, traffic: coachAudit, saveConversations: false)
                let judgeFactory = BrainClientFactory(keys: keys, proxyEndpoint: readiness?.endpoint, traffic: judgeAudit, saveConversations: false)
                let clients = coachFactory.makeClients(for: target, effort: effort)
                let executor = CoachingReplayExecutor(suite: suite, target: target, coach: clients.coach,
                    summarizer: clients.summarizer,
                    judge: judgeFactory.makeClients(for: judgeTarget, effort: judgeEffort).coach,
                    screen: NeutralReplayScreen())
                do {
                    var runErrors: [String] = []
                    if environment["JARVIS_EVALUATION_CALIBRATE_JUDGE"] == "1" {
                        let fixture = try JSONDecoder().decode(InterventionCalibration.self,
                            from: Data(contentsOf: LiveE2ELauncher.scenariosDirectory.appendingPathComponent("judge-calibration.json")))
                        var calibration: [String: InterventionVerdict] = [:]
                        for example in fixture.examples {
                            let verdict = try await InterventionVerdict.judge(client: judgeFactory.makeClients(for: judgeTarget, effort: judgeEffort).coach, input: example.evidence)
                            calibration[example.id] = verdict
                            if !example.matches(verdict) { runErrors.append("Judge calibration mismatch: \(example.id)") }
                        }
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(calibration).write(to: directory.appendingPathComponent("judge-calibration.json"))
                    }
                    var report = try await executor.run(catalog, metadata: metadata, output: directory)
                    let coachHealth = await coachAudit.close()
                    let judgeHealth = await judgeAudit.close()
                    if coachHealth != .complete { runErrors.append("Coach wire audit incomplete") }
                    if judgeHealth != .complete { runErrors.append("Judge wire audit incomplete") }
                    report.runErrors += runErrors
                    report.metadata["coachAuditHealth"] = String(describing: coachHealth)
                    report.metadata["judgeAuditHealth"] = String(describing: judgeHealth)
                    try report.write(to: directory)
                    let passed = report.passed
                    #expect(passed, "Behavior baseline failed; inspect evaluation.json, no retry or label tuning")
                } catch {
                    _ = await coachAudit.close(); _ = await judgeAudit.close(); throw error
                }
            }
        } catch { await proxy.stop(); throw error }
        await proxy.stop()
    }
    private func sourceFingerprint() throws -> String {
        let base = LiveE2ELauncher.repository
        var hash = SHA256()
        for folder in ["Sources/JarvisCore", "Sources/JarvisBrainProviders", "Sources/JarvisEvaluation", "Tests/JarvisLiveTests"] {
            let root = base.appendingPathComponent(folder)
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            let files = enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path < $1.path }
            for file in files {
                hash.update(data: Data(file.path.replacingOccurrences(of: base.path, with: "").utf8))
                hash.update(data: try Data(contentsOf: file))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
