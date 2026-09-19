import AppKit
import JarvisCore

// Design: wiki/architecture.md#onboarding
/// Runs once per install, before the rest of the app is built: asks for an API key, then the macOS
/// grants, skipping whichever is already in place. Closing the window before the end quits.
@MainActor
final class OnboardingGate: NSObject, NSWindowDelegate {
    private static let requiredPermissions = Set(JarvisReadiness.Permission.allCases)

    /// The host builds the rest of the app only after this fires.
    var onFinished: (() -> Void)?

    private let preferences: OnboardingPreferences
    private let permissionPreferences: PermissionPreferences
    private let secrets: any SecretStore
    private let keyStore: FileSecretStore
    private let brainPreferences: BrainPreferences
    private let transcriptionPreferences: TranscriptionPreferences
    private var window: NSWindow?
    private var stepContainer: NSView?
    private var steps: [Onboarding.Step] = []
    private var keyStep: APIKeyStepView?
    private var permissionsStep: PermissionsStepView?
    private var isComplete = false

    init(
        preferences: OnboardingPreferences,
        permissionPreferences: PermissionPreferences,
        secrets: any SecretStore,
        keyStore: FileSecretStore,
        brainPreferences: BrainPreferences,
        transcriptionPreferences: TranscriptionPreferences
    ) {
        self.preferences = preferences
        self.permissionPreferences = permissionPreferences
        self.secrets = secrets
        self.keyStore = keyStore
        self.brainPreferences = brainPreferences
        self.transcriptionPreferences = transcriptionPreferences
    }

    /// Once onboarding has completed, returns at once without probing anything.
    func begin() async {
        guard !preferences.isCompleted else {
            onFinished?()
            return
        }
        let needsAPIKey = Onboarding.needsAPIKey(
            secrets: secrets, brain: brainPreferences, transcription: transcriptionPreferences)
        let holdsGrants = await holdsEveryGrant()
        steps = Onboarding.steps(needsAPIKey: needsAPIKey, holdsEveryGrant: holdsGrants)
        guard let first = steps.first else {
            complete()
            return
        }
        present(first)
    }

    /// Runs the system-audio probe, which may prompt, only once the readable grants are held.
    private func holdsEveryGrant() async -> Bool {
        // Clear the asked marker once granted, or a later TCC reset would read as a refusal.
        if Permissions.isGranted(.screenRecording) {
            permissionPreferences.screenRecordingAsked = false
        }
        let readable = Self.requiredPermissions.subtracting([.systemAudio])
        guard Permissions.grantedReadinessPermissions().isSuperset(of: readable) else { return false }
        return await Permissions.request(.systemAudio, remembering: permissionPreferences)
    }

    private func present(_ first: Onboarding.Step) {
        NSApp.setActivationPolicy(.regular) // ghost-mode-allowed: first-run onboarding window
        if window == nil { build() }
        show(first)
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: first-run onboarding window
        window?.makeKeyAndOrderFront(nil) // ghost-mode-allowed: first-run onboarding window
    }

    private func build() {
        // With a full-size content view the content rect is the whole frame, bar included.
        let window = EscapableWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingStepView.size),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        // Kept for the Window menu and VoiceOver; the bar itself shows the backdrop.
        window.title = "Welcome to Jarvis"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        guard let content = window.contentView else { return }
        let background = SettingsBackgroundView(
            frame: content.bounds,
            center: OnboardingTheme.backgroundCenter, edge: OnboardingTheme.backgroundEdge)
        background.autoresizingMask = [.width, .height]
        let container = NSView(frame: content.bounds)
        container.autoresizingMask = [.width, .height]
        content.addSubview(background)
        content.addSubview(container)
        self.window = window
        self.stepContainer = container
    }

    private func show(_ step: Onboarding.Step) {
        guard let container = stepContainer, let index = steps.firstIndex(of: step) else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let quit = { NSApp.terminate(nil) }
        let view: NSView
        switch step {
        case .apiKey:
            let keyStep = APIKeyStepView(
                keyStore: keyStore,
                brainPreferences: brainPreferences,
                transcriptionPreferences: transcriptionPreferences,
                step: index + 1, of: steps.count, onQuit: quit)
            keyStep.onFinished = { [weak self] in self?.advance(past: .apiKey) }
            self.keyStep = keyStep
            view = keyStep
        case .permissions:
            let permissionsStep = PermissionsStepView(
                preferences: permissionPreferences,
                followsKeyStep: steps.first == .apiKey,
                step: index + 1, of: steps.count, onQuit: quit)
            permissionsStep.onFinished = { [weak self] in self?.complete() }
            self.permissionsStep = permissionsStep
            view = permissionsStep
        }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        if step == .apiKey, let keyStep {
            window?.makeFirstResponder(keyStep.initialFirstResponder)
        }
    }

    private func advance(past step: Onboarding.Step) {
        keyStep = nil
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            complete()
            return
        }
        show(steps[index + 1])
    }

    /// The one place the completed flag is written, with or without a window.
    private func complete() {
        preferences.isCompleted = true
        if Permissions.isGranted(.screenRecording) {
            permissionPreferences.screenRecordingAsked = false
        }
        isComplete = true
        if let window {
            window.performClose(nil)
        } else {
            onFinished?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: restoring the menu-bar-only app
        keyStep?.stop()
        permissionsStep?.stopObservingActivation()
        guard isComplete else {
            // Closing before the end is declining: Jarvis can't coach without a key and the grants.
            NSApp.terminate(nil)
            return
        }
        onFinished?()
    }
}
