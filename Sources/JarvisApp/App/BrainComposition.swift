import AppKit
import JarvisBrainProviders
import JarvisCore

@MainActor
protocol BrainCompositionHost: AnyObject {
    var liveCoachDriver: CoachDriver? { get }
    var liveSessionDirectory: URL? { get }
    var liveSessionEvidence: FileSessionAudit? { get }
    var isTranscriptionLive: Bool { get }
    func reportBrainError(
        _ error: UserFacingError, context: UserFacingError.PresentationContext)
    func brainTargetDidChange(_ target: BrainTarget?)
    func brainRecoveryDidChange(_ provider: BrainProvider?)
    func brainCycleDidFail(_ provider: BrainProvider)
}

@MainActor
final class BrainComposition {
    let preferences: BrainPreferences
    let supervisor: LocalProxySupervisor
    private let secrets: any SecretStore
    private unowned let host: BrainCompositionHost

    init(
        secrets: any SecretStore,
        host: BrainCompositionHost,
        supervisor: LocalProxySupervisor,
        preferences: BrainPreferences = BrainPreferences()
    ) {
        self.secrets = secrets
        self.host = host
        self.supervisor = supervisor
        self.preferences = preferences
    }

    /// Leaves the active target nil rather than the primary: the primary may be skipped as
    /// unavailable, and an early edit would then record a change away from a provider that never
    /// ran.
    func sessionWillStart() {
        activeBrainTarget = nil
        pendingBrainChangeFrom = nil
    }

    /// Deliberately leaves the helper running: it also serves Settings and the next Start.
    func sessionDidStop() {
        activeBrainTarget = nil
        pendingBrainChangeFrom = nil
    }

    private var activeBrainTarget: BrainTarget?
    private var pendingBrainChangeFrom: BrainTarget?
    private var brainUpdateRevision = 0

    private struct BrainRuntime {
        let coach: BrainClient
        let summarizer: BrainClient
    }

    /// Nil when the route has no subscription target, so such a route never starts the helper.
    func proxyReadiness(for route: BrainRoute) async -> LocalProxySupervisor.Readiness? {
        guard route.targets.contains(where: { $0.provider.servedByLocalProxy }) else { return nil }
        return await supervisor.readiness()
    }

    private func makeBrainRuntime(
        apiKey key: String,
        target: BrainTarget,
        effort: ReasoningEffort,
        proxyEndpoint: LocalProxySupervisor.Endpoint?
    ) -> BrainRuntime {
        let endpoint = target.provider.servedByLocalProxy ? proxyEndpoint : nil
        let summaryModel = BrainModelCatalog.summarizerModelID(for: target.provider)
        let coach = BrainAccessor(
            provider: target.provider,
            apiKey: endpoint?.key ?? key, model: target.modelID,
            reasoningEffort: effort.rawValue,
            endpoint: endpoint?.responsesURL ?? BrainProviderDescriptor.openAIResponsesEndpoint,
            timeout: BrainWorkloadTimeout.liveCoaching,
            maxOutputTokens: effort.maxOutputTokens,
            toolChoicePolicy: target.provider.toolChoicePolicy,
            minimumReasoningEffort: target.provider.reasoningEffortFloor,
            traffic: host.liveSessionEvidence, trafficTag: "coach")
        let summarizer = BrainAccessor(
            provider: target.provider,
            apiKey: endpoint?.key ?? key,
            model: summaryModel.isEmpty ? target.modelID : summaryModel,
            reasoningEffort: ReasoningEffort.low.rawValue,
            endpoint: endpoint?.responsesURL ?? BrainProviderDescriptor.openAIResponsesEndpoint,
            timeout: BrainWorkloadTimeout.historyCompaction, maxOutputTokens: 2_048,
            toolChoicePolicy: target.provider.toolChoicePolicy,
            minimumReasoningEffort: target.provider.reasoningEffortFloor,
            traffic: host.liveSessionEvidence, trafficTag: "summarizer")
        return BrainRuntime(coach: coach, summarizer: summarizer)
    }

    func unavailability(
        for target: BrainTarget,
        proxy: LocalProxySupervisor.Readiness?
    ) -> ProviderFailure? {
        guard target.provider.servedByLocalProxy else { return nil }
        return (proxy ?? .unavailable(reason: "isn't running")).unavailability(for: target.provider)
    }

    func routeUnavailability(
        _ route: BrainRoute,
        proxy: LocalProxySupervisor.Readiness?
    ) -> ProviderFailure? {
        let failures = route.targets.map { unavailability(for: $0, proxy: proxy) }
        guard failures.allSatisfy({ $0 != nil }) else { return nil }
        return failures.first.flatMap { $0 }
    }

    func makeConfiguredRoute(
        _ route: BrainRoute,
        proxy: LocalProxySupervisor.Readiness?,
        apiKey key: String,
        effort: ReasoningEffort,
        sessionDirectory: URL
    ) -> ConfiguredBrainRoute {
        let targets = route.targets.map { target -> ConfiguredBrainTarget in
            if let failure = unavailability(for: target, proxy: proxy) {
                return ConfiguredBrainTarget(unavailable: target, failure: failure)
            }
            let runtime = makeBrainRuntime(
                apiKey: key, target: target, effort: effort, proxyEndpoint: proxy?.endpoint)
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
                    self.host.liveSessionEvidence?.record(.brainChangeApplied(
                        previous: previous.provider,
                        current: target.provider))
                    self.pendingBrainChangeFrom = nil
                }
                self.activeBrainTarget = target
                self.host.brainTargetDidChange(target)
            },
            onAdvanced: { [weak self] previous, current, failure in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring route transition from a stopped or superseded session.")
                    return
                }
                self.host.liveSessionEvidence?.record(.brainRouteAdvanced(
                    previous: previous.provider, current: current.provider, failure: failure))
            },
            onSkipped: { [weak self] _, failure in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring unavailable-target notice from a stopped session.")
                    return
                }
                self.host.liveSessionEvidence?.record(
                    .brainRouteTargetSkipped(failure: failure))
            },
            onRecoveryChanged: { [weak self] provider in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else { return }
                self.host.brainRecoveryDidChange(provider)
            },
            onExhausted: { [weak self] target, _ in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else {
                    jlog("Jarvis: ignoring route exhaustion from a stopped or superseded session.")
                    return
                }
                self.host.brainCycleDidFail(target.provider)
            },
            onTerminated: { [weak self] target, failure in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else { return }
                self.host.reportBrainError(
                    .brainRouteExhausted(target: target, failure: failure), context: .runtime)
            },
            onRecoveryExpired: { [weak self] failure in
                guard let self, self.host.liveCoachDriver != nil,
                      self.host.liveSessionDirectory == sessionDirectory else { return }
                self.host.reportBrainError(.brainRecoveryExpired(failure: failure), context: .runtime)
            })
    }

    enum RunningBrainUpdate: Equatable {
        case topologyEdit
        case effortEdit
        case credentialRefresh
    }

    func applyBrainPreferencesToRunningSession(
        apiKeyOverride: String? = nil,
        update: RunningBrainUpdate
    ) async {
        guard host.liveCoachDriver != nil, host.isTranscriptionLive,
              let sessionDirectory = host.liveSessionDirectory
        else { return }
        // Two saves can resume out of order after awaiting the helper; the older must not install a
        // replaced API key.
        brainUpdateRevision += 1
        let revision = brainUpdateRevision
        let proxy = await proxyReadiness(for: preferences.route)
        guard let coachDriver = host.liveCoachDriver,
              host.isTranscriptionLive,
              host.liveSessionDirectory == sessionDirectory,
              revision == brainUpdateRevision
        else { return }
        let route = preferences.route
        let key = apiKeyOverride ?? secrets.apiKey(for: .openAIAPIKey) ?? ""
        guard !route.targets.contains(where: { $0.provider == .openAI }) || !key.isEmpty else {
            jlog("Jarvis: can't apply brain settings — an OpenAI target has no API key.")
            host.liveSessionEvidence?.record(.settingsChangeNotApplied)
            return
        }
        let provider = route.primary.provider
        // Refuse only an effort edit: rebuilding on a failed probe would retire working
        // subscription clients. A credential refresh swaps only OpenAI clients, so refusing it
        // would drop the key.
        let servesSubscription = route.targets.contains { $0.provider.servedByLocalProxy }
        if update == .effortEdit, servesSubscription, proxy?.endpoint == nil {
            jlog("Jarvis: skipped a brain refresh — the sign-in service didn't answer; "
                 + "the running route keeps its clients.")
            host.liveSessionEvidence?.record(.settingsChangeNotApplied)
            return
        }
        if update == .topologyEdit, let failure = routeUnavailability(route, proxy: proxy) {
            jlog("Jarvis: can't apply brain settings — no target in the route can coach: "
                 + (failure.errorDescription ?? ""))
            host.liveSessionEvidence?.record(.settingsChangeNotApplied)
            host.reportBrainError(.brainRouteUnavailable(failure: failure), context: .runtime)
            return
        }
        // The helper lists a vendor only once its credential loads, so a restart can briefly omit
        // it. Only a topology edit trusts that list; a reapply treats every subscription as signed
        // in.
        let availability: LocalProxySupervisor.Readiness?
        if update == .topologyEdit {
            availability = proxy
        } else if let endpoint = proxy?.endpoint {
            availability = .ready(endpoint, signedIn: Set(BrainProvider.allCases))
        } else {
            availability = proxy
        }
        let configuredRoute = makeConfiguredRoute(
            route,
            proxy: availability,
            apiKey: key,
            effort: preferences.effort,
            sessionDirectory: sessionDirectory)
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

    func applySavedAPIKey(_ key: String) {
        guard preferences.route.targets.contains(where: { $0.provider == .openAI }) else {
            jlog("Jarvis: saved API key will apply to future OpenAI transcription connections.")
            return
        }
        Task {
            await applyBrainPreferencesToRunningSession(apiKeyOverride: key, update: .credentialRefresh)
        }
    }
}
