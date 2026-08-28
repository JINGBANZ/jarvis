import AppKit
import JarvisBrainProviders
import JarvisCore

/// What brain composition needs to know about the live session, and how it reports back.
///
/// Deliberately narrow and one-directional: composition asks which session is live and what it is
/// coaching with, and reports through the runtime's existing error and Settings surfaces. It never
/// starts, stops, or tears anything down.
@MainActor
protocol BrainCompositionHost: AnyObject {
    /// The running session's event loop, or nil when nothing is coaching.
    var liveCoachDriver: CoachDriver? { get }
    /// The live session's directory, used both to tag CLI work and to reject a callback that
    /// belongs to a superseded session.
    var liveSessionDirectory: URL? { get }
    /// The live session's evidence handle: brain-traffic tagging and the fixed Activity notices.
    var liveSessionEvidence: FileSessionAudit? { get }
    /// Whether transcription is live. A brain reapply is only meaningful against a running pipeline.
    var isTranscriptionLive: Bool { get }
    /// The runtime owns every user-facing error presentation.
    func reportBrainError(
        _ error: UserFacingError, context: UserFacingError.PresentationContext)
    /// The Settings pane's active-target badge follows the route the session actually selected.
    func brainTargetDidChange(_ target: BrainTarget?)
}

/// Builds and reapplies the provider route.
///
/// One of the three owners the app delegate was split into (wiki/lean-coaching-core.md, Phase 5).
/// The boundary: **the session runtime** starts, stops, and tears down a session and applies
/// readiness and capture-health effects; **session artifacts** own what a session leaves on disk;
/// and **this type** owns provider preflight, brain-client construction, route construction, and
/// the live reapply of brain preferences and credentials.
///
/// It changes no lifecycle: a reapply installs a fresh route for the next attempt and returns.
/// Preflight failure leaves the current brain intact and reports the fixed *settings change not
/// applied* notice while the existing session continues.
@MainActor
final class BrainComposition {
    let preferences = BrainPreferences()
    /// Shared with the Settings sections so a detection performed there is the one this uses.
    let detector = AgentCLIDetector()
    private let secrets: any SecretStore
    private let coachTools: [ToolDef]
    private unowned let host: BrainCompositionHost

    init(secrets: any SecretStore, coachTools: [ToolDef], host: BrainCompositionHost) {
        self.secrets = secrets
        self.coachTools = coachTools
        self.host = host
    }

    /// The target a fresh session starts on, recorded so the first selection is not announced as a
    /// change.
    func sessionWillStart(on target: BrainTarget) {
        activeBrainTarget = target
        pendingBrainChangeFrom = nil
    }

    /// Forget the session's route identity at teardown.
    func sessionDidStop() {
        activeBrainTarget = nil
        pendingBrainChangeFrom = nil
    }

    /// Runtime route state for truthful Settings and Activity updates. A Settings edit is announced
    /// only when the replacement route actually selects its first target for a fresh attempt.
    private var activeBrainTarget: BrainTarget?
    private var pendingBrainChangeFrom: BrainTarget?

    /// The two clients that move together with one provider/model route target.
    private struct BrainRuntime {
        let coach: BrainClient
        let summarizer: BrainClient
    }

    /// Check the selected local provider before disturbing a live session. OpenAI needs no provider
    /// preflight; a missing/signed-out CLI leaves the current brain intact and reports fixed Activity
    /// copy while raw detection detail stays in the debug log.
    func preflightBrainProvider(_ provider: BrainProvider,
                                        detectedCLI: DetectedAgentCLI?,
                                        context: UserFacingError.PresentationContext,
                                        recordSettingsFailure: Bool)
        -> (isReady: Bool, cli: DetectedAgentCLI?) {
        guard provider.usesLocalCLI else { return (true, nil) }
        let action = recordSettingsFailure ? "apply brain settings" : "start"
        guard let cli = detectedCLI else {
            jlog("Jarvis: can't \(action) — \(provider.displayName) CLI not found.")
            if recordSettingsFailure { host.liveSessionEvidence?.record(.settingsChangeNotApplied) }
            host.reportBrainError(
                .brainCLIMissing(provider: provider.displayName), context: context)
            return (false, nil)
        }
        switch cli.authenticationStatus {
        case .signedIn:
            break
        case .signedOut:
            jlog("Jarvis: can't \(action) — \(provider.displayName) isn't signed in.")
            if recordSettingsFailure { host.liveSessionEvidence?.record(.settingsChangeNotApplied) }
            host.reportBrainError(
                .brainCLINotSignedIn(provider: provider.displayName), context: context)
            return (false, nil)
        case .unknown:
            host.reportBrainError(
                .brainCLISignInUnconfirmed(provider: provider.displayName), context: context)
        }
        return (true, cli)
    }

    /// Construct the coach + compaction clients for one preferences snapshot. Both keep writing to
    /// the current session's traffic recorder, so a hot switch remains one auditable conversation.
    private func makeBrainRuntime(
        apiKey key: String,
        target: BrainTarget,
        effort: ReasoningEffort,
        cli: DetectedAgentCLI?,
        sharedCLIRuntime: CLIBrainRuntime? = nil,
        prewarm: Bool = true
    ) -> BrainRuntime {
        let coachBase: BrainClient
        let summarizer: BrainClient
        if let cli {
            let sessionDir = host.liveSessionDirectory ?? sessionDirectoryFallback()
            let runtimes = LocalAgentRuntimeSet(
                provider: target.provider,
                codexSupportedFeatures: cli.supportedFeatures,
                sharedCoach: sharedCLIRuntime)
            coachBase = CLIBrainClient(provider: target.provider, executable: cli.executableURL,
                                       model: target.modelID,
                                       reasoningEffort: effort.rawValue,
                                       workDirectory: sessionDir,
                                       timeout: BrainWorkloadTimeout.liveCoaching,
                                       traffic: host.liveSessionEvidence, trafficTag: "coach",
                                       systemPrompt: JarvisPrompts.Coach.system,
                                       tools: coachTools,
                                       toolChoice: .required,
                                       runtime: runtimes.coach,
                                       prewarm: prewarm)
            summarizer = CLIBrainClient(provider: target.provider, executable: cli.executableURL,
                                        model: BrainModelCatalog.summarizerModelID(for: target.provider),
                                        reasoningEffort: ReasoningEffort.low.rawValue,
                                        workDirectory: sessionDir,
                                        timeout: BrainWorkloadTimeout.historyCompaction,
                                        traffic: host.liveSessionEvidence, trafficTag: "summarizer",
                                        systemPrompt: JarvisPrompts.HistorySummary.system,
                                        tools: [],
                                        toolChoice: .auto,
                                        runtime: runtimes.summarizer,
                                        prewarm: false)
        } else {
            coachBase = OpenAIBrainClient(
                apiKey: key, model: target.modelID,
                reasoningEffort: effort.rawValue,
                timeout: BrainWorkloadTimeout.liveCoaching,
                maxOutputTokens: effort.maxOutputTokens,
                traffic: host.liveSessionEvidence, trafficTag: "coach")
            summarizer = OpenAIBrainClient(
                apiKey: key, model: BrainModelCatalog.summarizerModelID(for: .openAI),
                reasoningEffort: ReasoningEffort.low.rawValue,
                timeout: BrainWorkloadTimeout.historyCompaction, maxOutputTokens: 2_048,
                traffic: host.liveSessionEvidence, trafficTag: "summarizer")
        }
        return BrainRuntime(coach: coachBase, summarizer: summarizer)
    }

    /// Missing or definitively signed-out fallback CLIs remain in the runtime route as unavailable
    /// entries. The driver skips them only if the session cursor reaches them.
    func fallbackUnavailability(
        for target: BrainTarget,
        detectedCLI: DetectedAgentCLI?
    ) -> String? {
        guard target.provider.usesLocalCLI else { return nil }
        guard let detectedCLI else {
            return "\(target.provider.displayName) CLI was not found"
        }
        if detectedCLI.authenticationStatus == .signedOut {
            return "\(target.provider.displayName) is signed out"
        }
        return nil
    }

    func makeConfiguredRoute(
        _ route: BrainRoute,
        detectedCLIs: [BrainProvider: DetectedAgentCLI],
        apiKey key: String,
        effort: ReasoningEffort,
        sessionDirectory: URL,
        prewarmPrimary: Bool = true
    ) -> ConfiguredBrainRoute {
        let sharedCodexRuntime = route.targets.contains {
            $0.provider == .codexCLI && detectedCLIs[$0.provider] != nil
        } ? CLIBrainRuntime(
            provider: .codexCLI,
            codexSupportedFeatures: detectedCLIs[.codexCLI]?.supportedFeatures ?? []) : nil
        let targets = route.targets.enumerated().map { index, target -> ConfiguredBrainTarget in
            let cli = detectedCLIs[target.provider]
            if let detail = fallbackUnavailability(for: target, detectedCLI: cli) {
                return ConfiguredBrainTarget(unavailable: target, detail: detail)
            }
            let runtime = makeBrainRuntime(
                apiKey: key,
                target: target,
                effort: effort,
                cli: cli,
                sharedCLIRuntime: target.provider == .codexCLI ? sharedCodexRuntime : nil,
                prewarm: prewarmPrimary && index == 0)
            return ConfiguredBrainTarget(
                target: target, brain: runtime.coach, summarizer: runtime.summarizer)
        }

        return ConfiguredBrainRoute(
            targets: targets,
            onSelected: { [weak self] target in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring target selection from a stopped or superseded session.")
                    return
                }
                if let previous = self.pendingBrainChangeFrom {
                    host.liveSessionEvidence?.record(.brainChangeApplied(
                        previous: previous.provider,
                        current: target.provider))
                    self.pendingBrainChangeFrom = nil
                }
                self.activeBrainTarget = target
                self.host.brainTargetDidChange(target)
            },
            onAdvanced: { [weak self] previous, current in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring route transition from a stopped or superseded session.")
                    return
                }
                host.liveSessionEvidence?.record(.brainRouteAdvanced(
                    previous: previous.provider, current: current.provider))
            },
            onSkipped: { [weak self] target in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring unavailable-target notice from a stopped session.")
                    return
                }
                host.liveSessionEvidence?.record(
                    .brainRouteTargetSkipped(provider: target.provider))
            },
            onExhausted: { [weak self] target, failure in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring route exhaustion from a stopped or superseded session.")
                    return
                }
                host.reportBrainError(
                    .brainRouteExhausted(
                        lastProvider: target.provider,
                        reason: failure.detail),
                    context: .runtime)
            })
    }

    enum RunningBrainUpdate: Equatable {
        case topologyEdit
        case effortEdit
        case credentialRefresh
    }

    /// Apply provider/model topology or effort changes without touching capture, transcription,
    /// history, or the session directory. An in-flight turn finishes on its old client snapshot.
    func applyBrainPreferencesToRunningSession(
        detectedCLIs: [BrainProvider: DetectedAgentCLI]?,
        apiKeyOverride: String? = nil,
        update: RunningBrainUpdate
    ) {
        guard let coachDriver = host.liveCoachDriver,
              host.isTranscriptionLive,
              let sessionDirectory = host.liveSessionDirectory
        else { return }
        let route = preferences.route
        let key = apiKeyOverride ?? secrets.apiKey() ?? ""
        guard !route.targets.contains(where: { $0.provider == .openAI }) || !key.isEmpty else {
            jlog("Jarvis: can't apply brain settings — an OpenAI target has no API key.")
            host.liveSessionEvidence?.record(.settingsChangeNotApplied)
            return
        }
        let provider = route.primary.provider
        var readyCLIs = detectedCLIs ?? [:]
        if update == .topologyEdit {
            let preflight = preflightBrainProvider(
                provider,
                detectedCLI: detectedCLIs?[provider],
                context: .runtime,
                recordSettingsFailure: true)
            guard preflight.isReady else { return }
            if let cli = preflight.cli {
                readyCLIs[provider] = cli
            }
        }
        let configuredRoute = makeConfiguredRoute(
            route,
            detectedCLIs: readyCLIs,
            apiKey: key,
            effort: preferences.effort,
            sessionDirectory: sessionDirectory,
            prewarmPrimary: update == .topologyEdit)
        switch update {
        case .topologyEdit:
            if pendingBrainChangeFrom == nil {
                pendingBrainChangeFrom = activeBrainTarget
            }
            coachDriver.updateBrainRoute(configuredRoute)
            let model = route.primary.model ?? BrainModelCatalog.defaultModel(for: provider)
            jlog("Jarvis: brain settings will apply on the next turn — \(provider.displayName), "
                 + "\(model.displayName), \(preferences.effort.displayName) effort.")
        case .effortEdit:
            guard coachDriver.reconfigureBrainRouteClients(configuredRoute) else {
                jlog("Jarvis: skipped stale effort refresh after the route topology changed.")
                return
            }
            jlog("Jarvis: reasoning effort will apply on the next coaching attempt.")
        case .credentialRefresh:
            guard coachDriver.refreshBrainRouteClients(configuredRoute, for: [.openAI]) else {
                jlog("Jarvis: skipped stale API-key brain refresh after the route topology changed.")
                return
            }
            jlog("Jarvis: saved API key will apply to OpenAI on the next coaching attempt.")
        }
    }

    /// Keep a healthy live conversation intact when the credential file changes: install fresh
    /// OpenAI target clients between coaching attempts without probing or replacing CLI clients,
    /// changing route policy, or restarting transcription.
    func applySavedAPIKey(_ key: String) {
        guard preferences.route.targets.contains(where: { $0.provider == .openAI }) else {
            jlog("Jarvis: saved API key will apply to future OpenAI transcription connections.")
            return
        }
        applyBrainPreferencesToRunningSession(
            detectedCLIs: nil,
            apiKeyOverride: key,
            update: .credentialRefresh)
    }

    /// Where a CLI brain materializes screenshots before a session exists. Only reached when no
    /// session is live, which cannot happen on the coaching path.
    private func sessionDirectoryFallback() -> URL {
        FileSecretStore().fileURL.deletingLastPathComponent().appendingPathComponent("sessions")
    }
}
