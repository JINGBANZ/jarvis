import Foundation
import JarvisCore

// Design: wiki/settings-window.md#status
@MainActor
final class SettingsHubModel {
    private(set) var state = RobotHubState.empty

    private let brainPreferences: BrainPreferences
    private let transcriptionPreferences: TranscriptionPreferences
    private let screenPreferences: ScreenCapturePreferences
    private let appearance: OverlayAppearance
    private let secrets: any SecretStore
    private let signIns: SubscriptionSignIns
    private var activeTarget: BrainTarget?
    private var observers: [UUID: (RobotHubState) -> Void] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private var refreshScheduled = false

    init(
        brainPreferences: BrainPreferences,
        transcriptionPreferences: TranscriptionPreferences,
        screenPreferences: ScreenCapturePreferences,
        appearance: OverlayAppearance,
        secrets: any SecretStore,
        signIns: SubscriptionSignIns
    ) {
        self.brainPreferences = brainPreferences
        self.transcriptionPreferences = transcriptionPreferences
        self.screenPreferences = screenPreferences
        self.appearance = appearance
        self.secrets = secrets
        self.signIns = signIns
        // The model lives as long as the app, so this observer is never removed.
        signIns.observe { [weak self] in self?.refresh(probe: false) }
        refresh(probe: false)
    }

    /// With `probe`, the fresh sign-in answer arrives later through the sign-in observer.
    func refresh(probe: Bool) {
        if probe { signIns.refresh() }
        publish(RobotHub.state(for: inputs()))
    }

    func setActiveTarget(_ target: BrainTarget?) {
        activeTarget = target
        refresh(probe: false)
    }

    @discardableResult
    func observe(_ handler: @escaping (RobotHubState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    func beginObservingSettings() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    func endObservingSettings() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.refresh(probe: false)
        }
    }

    private func inputs() -> RobotHubInputs {
        let route = brainPreferences.route
        return RobotHubInputs(
            route: route,
            effort: brainPreferences.effort,
            transcription: transcriptionPreferences.configuration,
            screenScope: screenPreferences.scope,
            displayIndex: screenPreferences.displayIndex,
            browserTextEnabled: screenPreferences.browserTextEnabled && BrowserAccessibilityPermission.isGranted,
            boxFontSize: appearance.boxFontSize,
            readiness: RobotReadiness(
                signedOutSubscriptions: signIns.signedOut(
                    among: Set(route.targets.map(\.provider).filter(\.servedByLocalProxy))),
                availableCredentials: Set(Credential.allCases.filter {
                    secrets.apiKey(for: $0)?.isEmpty == false
                }),
                grantedPermissions: Set([JarvisReadiness.Permission.microphone, .screenRecording]
                    .filter { Permissions.isGranted($0) })),
            activeTarget: activeTarget)
    }

    private func publish(_ newState: RobotHubState) {
        guard newState != state else { return }
        state = newState
        for handler in observers.values { handler(newState) }
    }
}
