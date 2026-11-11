#if JARVIS_LIVE_E2E
import Foundation
import CryptoKit
import JarvisCore
import JarvisBrainProviders
import JarvisProcess

public struct EvaluationSuiteRunner {
    public enum Failure: LocalizedError {
        case invalidConfiguration, missingValue(String), sameCoachAndJudgeModel

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "Invalid evaluation suite configuration"
            case .missingValue(let message): message
            case .sameCoachAndJudgeModel:
                "Coach and judge must use different model IDs. Set JARVIS_EVALUATION_MODEL or JARVIS_EVALUATION_JUDGE_MODEL."
            }
        }
    }
    let environment: [String: String]
    let repository: URL
    let scenariosDirectory: URL
    let launcher: any ProcessLaunching
    let screen: any ScreenCapturing
    let signedApp: (SignedAppEvaluationRun, EvaluationSuiteCatalog.Entry) async throws -> SignedAppEvaluationEvidence

    public init(environment: [String: String], repository: URL, launcher: any ProcessLaunching,
                screen: any ScreenCapturing,
                signedApp: @escaping (SignedAppEvaluationRun, EvaluationSuiteCatalog.Entry) async throws -> SignedAppEvaluationEvidence) {
        self.environment = environment; self.repository = repository
        self.scenariosDirectory = repository.appendingPathComponent("Tests/JarvisLiveTests/Scenarios")
        self.launcher = launcher; self.screen = screen; self.signedApp = signedApp
    }

    private func require<T>(_ value: T?, _ message: String = "Missing evaluation input") throws -> T {
        guard let value else { throw Failure.missingValue(message) }
        return value
    }
    public func run() async throws -> [EvaluationSuiteReport] {
        do { return try await runSelectedSuite() }
        catch {
            if let path = environment["JARVIS_LIVE_E2E_RUN_DIR"] {
                try EvaluationSuiteReport(suite: environment["JARVIS_EVALUATION_SUITE"] ?? "unknown",
                    results: [], runErrors: [ProviderMessageRedaction.redact(error.localizedDescription)])
                    .write(to: URL(fileURLWithPath: path))
            }
            throw error
        }
    }

    private func runSelectedSuite() async throws -> [EvaluationSuiteReport] {
        var reports: [EvaluationSuiteReport] = []
        guard let suite = environment["JARVIS_EVALUATION_SUITE"],
              let path = environment["JARVIS_LIVE_E2E_RUN_DIR"],
              let repeats = Int(environment["JARVIS_EVALUATION_REPEAT"] ?? ""), repeats > 0,
              let provider = BrainProvider(rawValue: environment["JARVIS_LIVE_E2E_PROVIDER"] ?? "") else {
            throw Failure.invalidConfiguration
        }
        let root = URL(fileURLWithPath: path)
        let suiteCatalog = try EvaluationSuiteCatalog.load(from: scenariosDirectory.appendingPathComponent("evaluation-suites.json"))
        let selected = try require(suiteCatalog.suites.first { $0.id == suite })
        if selected.executor == .signedApp {
            for index in 1...repeats {
                let layout = SignedAppEvaluationRun(runDirectory: root, repeatIndex: index)
                let directory = layout.reportDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let evidence = try await signedApp(layout, selected)
                let raw = evidence.results
                let lines = raw.split(separator: "\n")
                let checks = lines.filter { $0.split(separator: " ").dropFirst().first == "pass" || $0.split(separator: " ").dropFirst().first == "fail" }
                let finished = evidence.finished
                let results = checks.map { line in
                    let fields = line.split(separator: " ")
                    return EvaluationDecisionResult(id: String(fields[0]), expectation: .eitherAcceptable,
                        evidence: .init(completed: finished, outcome: String(line), replies: [], assertionsPassed: fields[1] == "pass"), verdict: nil)
                }
                let report = EvaluationSuiteReport(suite: suite, results: results, metadata: ["adapter": "signed-app", "provider": provider.rawValue, "acceptance": selected.acceptance,
                    "rawEvidenceDirectory": evidence.directory.path,
                    "sourceRevision": environment["JARVIS_EVALUATION_SOURCE_REVISION"] ?? "unknown", "sourceSHA256": try sourceFingerprint()])
                try report.write(to: directory)
                reports.append(report)
            }
            return reports
        }
        let catalogURL = scenariosDirectory.appendingPathComponent(try require(selected.catalog))
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try CoachingReplayCatalog.load(from: catalogURL)
        let target = LiveE2EScenario.target(for: provider, modelID: environment["JARVIS_EVALUATION_MODEL"])
        let judgeProvider = try require(BrainProvider(rawValue: environment["JARVIS_EVALUATION_JUDGE_PROVIDER"] ?? TestProviderConfiguration.shared.defaultJudgeProvider.rawValue), "Invalid judge provider")
        let judgeTarget = Self.judgeTarget(for: judgeProvider, modelID: environment["JARVIS_EVALUATION_JUDGE_MODEL"])
        guard judgeTarget.modelID != target.modelID else { throw Failure.sameCoachAndJudgeModel }
        let effort = try require(ReasoningEffort(rawValue: environment["JARVIS_EVALUATION_EFFORT"] ?? Defaults.Brain.effort.rawValue), "Invalid coach reasoning effort")
        let judgeEffort = try require(ReasoningEffort(rawValue: environment["JARVIS_EVALUATION_JUDGE_EFFORT"] ?? ReasoningEffort.low.rawValue), "Invalid judge reasoning effort")
        let needsProxy = provider.servedByLocalProxy || judgeProvider.servedByLocalProxy
        let proxy = LocalProxySupervisor(executable: LocalProxySupervisor.bundledExecutable(),
            home: FileSecretStore().directoryURL.appendingPathComponent("proxy"), launcher: launcher)
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
                "judgeInstructionVersion": InterventionVerdict.judgeInstructionVersion,
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
                    screen: screen)
                do {
                    var runErrors: [String] = []
                    if environment["JARVIS_EVALUATION_CALIBRATE_JUDGE"] == "1" {
                        let fixture = try JSONDecoder().decode(InterventionCalibration.self,
                            from: Data(contentsOf: scenariosDirectory.appendingPathComponent("judge-calibration.json")))
                        var calibration: [String: InterventionVerdict] = [:]
                        for example in fixture.examples {
                            let verdict = try await InterventionVerdict.judge(client: judgeFactory.makeClients(for: judgeTarget, effort: judgeEffort).coach, input: example.evidence)
                            calibration[example.id] = verdict
                            if !example.matches(verdict) { runErrors.append("Judge calibration mismatch: \(example.id)") }
                        }
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(calibration).write(to: directory.appendingPathComponent("judge-calibration.json"))
                    }
                    var report: EvaluationSuiteReport
                    if runErrors.isEmpty {
                        report = try await executor.run(catalog, metadata: metadata, output: directory)
                    } else {
                        report = EvaluationSuiteReport(suite: suite, results: [], metadata: metadata)
                    }
                    let coachHealth = await coachAudit.close()
                    let judgeHealth = await judgeAudit.close()
                    if coachHealth != .complete { runErrors.append("Coach wire audit incomplete") }
                    if judgeHealth != .complete { runErrors.append("Judge wire audit incomplete") }
                    report.runErrors += runErrors
                    report.metadata["coachAuditHealth"] = String(describing: coachHealth)
                    report.metadata["judgeAuditHealth"] = String(describing: judgeHealth)
                    try report.write(to: directory)
                    reports.append(report)
                } catch {
                    _ = await coachAudit.close(); _ = await judgeAudit.close(); throw error
                }
            }
        } catch { await proxy.stop(); throw error }
        await proxy.stop()
        return reports
    }
    static func judgeTarget(for provider: BrainProvider, modelID: String? = nil) -> BrainTarget {
        LiveE2EScenario.target(for: provider,
            modelID: modelID ?? TestProviderConfiguration.shared.modelID(for: provider, judge: true))
    }

    private func sourceFingerprint() throws -> String {
        let base = repository
        var hash = SHA256()
        for folder in ["Sources/JarvisCore", "Sources/JarvisBrainProviders", "Sources/JarvisEvaluation", "Tests/JarvisLiveTests", "Tests/Support/ScenarioHarness", "Tests/Support/ProcessOwnership", "Sources/JarvisApp/Testing"] {
            let root = base.appendingPathComponent(folder)
            let enumerator = try require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            let files = enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path < $1.path }
            for file in files {
                hash.update(data: Data(file.path.replacingOccurrences(of: base.path, with: "").utf8))
                hash.update(data: try Data(contentsOf: file))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

}

#endif
