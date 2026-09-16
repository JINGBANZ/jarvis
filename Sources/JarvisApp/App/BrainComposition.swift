import AppKit
import JarvisBrainProviders
import JarvisCore

/// What brain composition needs to know about the live session, and how it reports back.
///
/// Deliberately narrow and one-directional: composition asks which session is live and what it is
/// coaching with, and reports through the runtime's existing error and Settings surfaces. It never
/// starts or stops a session.
@MainActor
protocol BrainCompositionHost: AnyObject {
    /// The running session's event loop, or nil when nothing is coaching.
    var liveCoachDriver: CoachDriver? { get }
    /// The live session's directory, used to reject a callback that belongs to a superseded session.
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
    func brainRecoveryDidChange(_ provider: BrainProvider?)
    func brainCycleDidFail(_ provider: BrainProvider)
}

/// Builds and reapplies the provider route.
///
/// One of the three owners the app delegate was split into (wiki/lean-coaching-core.md, Phase 5).
/// The boundary: **the session runtime** starts, stops, and tears down a session and applies
/// readiness and capture-health effects; **session artifacts** own what a session leaves on disk;
/// and **this type** owns route readiness, brain-client construction, route construction, and the
/// live reapply of brain preferences and credentials.
///
/// It changes no lifecycle: a reapply installs a fresh route for the next attempt and returns. A
/// refused reapply leaves the current brain intact and reports the fixed *settings change not
/// applied* notice while the existing session continues.
@MainActor
final class BrainComposition {
    /// The route, effort, and capability switches a Start and every live reapply read. Normal launches
    /// use the standard defaults; a caller with its own isolated suite passes that instead.
    let preferences: BrainPreferences
    /// The bundled helper serving the subscription targets, shared with Settings.
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

    /// A fresh session has no active target until the route selects one. Naming the primary here
    /// claimed a provider that may never serve: an unavailable one is skipped, and a topology edit
    /// made before the first attempt then recorded a change away from a provider that never ran.
    /// `onSelected` fills this in, and finds no pending change, so a first selection stays silent.
    func sessionWillStart() {
        activeBrainTarget = nil
        pendingBrainChangeFrom = nil
    }

    /// Forget the session's route identity at teardown. The helper is not the session's to stop: it
    /// serves Settings and the next Start too.
    func sessionDidStop() {
        activeBrainTarget = nil
        pendingBrainChangeFrom = nil
    }

    /// Runtime route state for truthful Settings and Activity updates. A Settings edit is announced
    /// only when the replacement route actually selects its first target for a fresh attempt.
    private var activeBrainTarget: BrainTarget?
    private var pendingBrainChangeFrom: BrainTarget?
    /// Bumped by every reapply, so one that resumes after a newer one installs nothing.
    private var brainUpdateRevision = 0

    /// The two clients that move together with one provider/model route target.
    private struct BrainRuntime {
        let coach: BrainClient
        let summarizer: BrainClient
    }

    /// The helper's state for a route, read once per Start or reapply; nil when no target in the
    /// route is a subscription, so a route without one never starts the helper.
    func proxyReadiness(for route: BrainRoute) async -> LocalProxySupervisor.Readiness? {
        guard route.targets.contains(where: { $0.provider.servedByLocalProxy }) else { return nil }
        return await supervisor.readiness()
    }

    /// Construct the coach + compaction clients for one preferences snapshot. Both keep writing to
    /// the current session's traffic recorder, so a hot switch remains one auditable conversation.
    /// One HTTP client serves OpenAI and both subscriptions; only the endpoint, the key, and the
    /// target's tool policy and reasoning floor differ.
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
            endpoint: endpoint?.responsesURL ?? BrainAccessor.openAIEndpoint,
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
            endpoint: endpoint?.responsesURL ?? BrainAccessor.openAIEndpoint,
            timeout: BrainWorkloadTimeout.historyCompaction, maxOutputTokens: 2_048,
            toolChoicePolicy: target.provider.toolChoicePolicy,
            minimumReasoningEffort: target.provider.reasoningEffortFloor,
            traffic: host.liveSessionEvidence, trafficTag: "summarizer")
        return BrainRuntime(coach: coach, summarizer: summarizer)
    }

    /// Why a route target cannot serve this session, or nil when it can: a subscription the helper
    /// cannot serve. Such a target stays in the runtime route as an unavailable entry, which the
    /// driver skips only if the session cursor reaches it.
    func unavailability(
        for target: BrainTarget,
        proxy: LocalProxySupervisor.Readiness?
    ) -> ProviderFailure? {
        guard target.provider.servedByLocalProxy else { return nil }
        return (proxy ?? .unavailable(reason: "isn't running")).unavailability(for: target.provider)
    }

    /// The first target's failure when no target in the route can serve, so a Start or a route edit
    /// is refused instead of installing a route that could never coach. Nil when one target can.
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

    /// Apply provider/model topology or effort changes without touching capture, transcription,
    /// history, or the session directory. An in-flight turn finishes on its old client snapshot.
    /// Returns once the change is installed or refused; a route with a subscription target reads
    /// the helper first, so the edit meets the sign-ins Settings showed.
    func applyBrainPreferencesToRunningSession(
        apiKeyOverride: String? = nil,
        update: RunningBrainUpdate
    ) async {
        guard host.liveCoachDriver != nil, host.isTranscriptionLive,
              let sessionDirectory = host.liveSessionDirectory
        else { return }
        // Two saves in a row both wait on the helper here and can resume out of order; the older one
        // would then install its own snapshot, an API key the user has already replaced.
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
        // An effort or key edit keeps the route it has. Rebuilding it against a probe that just
        // failed would replace working subscription clients with permanently unavailable targets,
        // and an unavailable target at the active cursor exhausts the route, which ends a
        // subscription-only session. The running clients hold the same endpoint either way.
        //
        // A probe that answers without naming the vendor counts as failing here too: the helper
        // lists a vendor's models only once it has loaded that credential, so a restart or a token
        // refresh can answer for a moment without it. The live client keeps working, and a
        // credential that really is gone surfaces as the helper's own 503 on the next request.
        let servesSubscription = route.targets.contains { $0.provider.servedByLocalProxy }
        if update != .topologyEdit, servesSubscription, proxy?.endpoint == nil {
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
        // A reapply rebuilds clients for a route the session is already running. The helper answered,
        // so every subscription in it keeps a usable endpoint; whether this moment's model list named
        // the vendor decides nothing here, and treating it as authoritative would retire a working
        // target permanently. Only a topology edit, which installs targets the user just chose, reads
        // the probe as it came.
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

    /// Keep a healthy live conversation intact when the credential file changes: install fresh
    /// OpenAI target clients between coaching attempts without replacing subscription clients,
    /// changing route policy, or restarting transcription.
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
