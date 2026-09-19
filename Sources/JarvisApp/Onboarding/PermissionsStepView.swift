import AppKit
import JarvisCore

// Design: wiki/architecture.md#permissions
/// Onboarding's permissions step.
@MainActor
final class PermissionsStepView: NSView {
    var onFinished: (() -> Void)?

    private let preferences: PermissionPreferences
    private var rows: [JarvisReadiness.Permission: PermissionRowView] = [:]
    private var shell: OnboardingStepView?
    private var isRequesting = false
    private var activationObserver: (any NSObjectProtocol)?
    private var asking: JarvisReadiness.Permission?
    private var sentToSettings: Set<JarvisReadiness.Permission> = []
    private var hasWalked = false
    /// Read at init, before this launch asks: only an earlier, still-missing ask proves refusal.
    private let screenAskedInEarlierLaunch: Bool

    init(
        preferences: PermissionPreferences, followsKeyStep: Bool,
        step index: Int, of count: Int, onQuit: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.screenAskedInEarlierLaunch = preferences.screenRecordingAsked
        super.init(frame: NSRect(origin: .zero, size: OnboardingStepView.size))

        let shell = OnboardingStepView(
            lit: [.ear, .eye],
            title: followsKeyStep ? "Now three things from macOS." : "Hi, I’m Jarvis.",
            lede: followsKeyStep
                ? "So I can hear your call and see your screen. macOS asks one at a time."
                : "I need three things from macOS, so I can hear your call and see your screen.",
            body: makeList(), step: index, of: count, onQuit: onQuit,
            onPrimary: { [weak self] in self?.primaryAction() })
        shell.frame = bounds
        shell.autoresizingMask = [.width, .height]
        addSubview(shell)
        self.shell = shell

        // Re-render on return from System Settings, so the label matches what a click will do.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRequesting else { return }
                self.render()
            }
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func stopObservingActivation() {
        guard let activationObserver else { return }
        NotificationCenter.default.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    // MARK: - The walk

    private func primaryAction() {
        guard !isRequesting else { return }
        switch terminalState {
        case .none:
            requestAll()
        case .refused(let refused):
            recheck(refused)
        case .needsRelaunch:
            relaunch()
        case .satisfied:
            onFinished?()
        }
    }

    /// One dialog at a time: macOS queues TCC dialogs, and several at once stack confusingly.
    private func requestAll() {
        isRequesting = true
        render()
        Task { @MainActor in
            for permission in JarvisReadiness.Permission.allCases
            where !Permissions.isGranted(permission) {
                asking = permission
                render()
                _ = await Permissions.request(permission, remembering: preferences)
            }
            asking = nil
            isRequesting = false
            hasWalked = true
            render()
        }
    }

    /// System audio can't be read, so re-prove it before sending the user back to its toggle.
    private func recheck(_ refused: [JarvisReadiness.Permission]) {
        guard refused.contains(.systemAudio) else {
            openSystemSettings(for: refused)
            return
        }
        isRequesting = true
        render()
        Task { @MainActor in
            _ = await Permissions.request(.systemAudio, remembering: preferences)
            isRequesting = false
            render()
            if case .refused(let stillRefused) = terminalState {
                openSystemSettings(for: stillRefused)
            }
        }
    }

    private func openSystemSettings(for permissions: [JarvisReadiness.Permission]) {
        // Screen and system audio share one pane on macOS 15+, and a click opens only one pane.
        let opensMicrophonePane = permissions.first == .microphone
        let anchor = opensMicrophonePane ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        let covered = permissions.filter { ($0 == .microphone) == opensMicrophonePane }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        // Record a visit only if the pane opened, or the button would jump to a pointless relaunch.
        guard NSWorkspace.shared.open(url) else { // ghost-mode-allowed: explicit click on onboarding's permissions step
            jlog("Jarvis: couldn't open the \(anchor) settings pane")
            return
        }
        sentToSettings.formUnion(covered)
        render()
    }

    /// A new Screen Recording grant shows only in a new process. Safe only here: no session runs.
    private func relaunch() {
        // Blocks a second click, which would launch a second instance.
        isRequesting = true
        render()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication( // ghost-mode-allowed: explicit click on onboarding's permissions step
            at: Bundle.main.bundleURL, configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                guard error == nil else {
                    // Quitting now would leave the user with nothing running.
                    jlog("Jarvis: relaunch failed — \(String(describing: error))")
                    self?.isRequesting = false
                    self?.render()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - State

    private enum TerminalState {
        case none
        case refused([JarvisReadiness.Permission])
        case needsRelaunch
        case satisfied
    }

    private var terminalState: TerminalState {
        guard !isRequesting else { return .none }
        let missing = JarvisReadiness.Permission.allCases.filter {
            !Permissions.isGranted($0)
        }
        guard !missing.isEmpty else { return .satisfied }

        let refused = missing.filter(isBeyondAsking)
        // After this launch asked, macOS reveals the Screen Recording answer only to a new process.
        let askable = missing.filter {
            !refused.contains($0) && !($0 == .screenRecording && hasWalked)
        }
        if !askable.isEmpty { return .none }
        // After a Settings visit, only a relaunch shows whether Screen Recording was switched on.
        if refused == [.screenRecording], sentToSettings.contains(.screenRecording) {
            return .needsRelaunch
        }
        if !refused.isEmpty { return .refused(refused) }
        return .needsRelaunch
    }

    /// True when macOS has answered, so asking again is a silent no-op.
    private func isBeyondAsking(_ permission: JarvisReadiness.Permission) -> Bool {
        switch permission {
        case .screenRecording:
            // Also ask once this launch: the flag survives `tccutil reset`, which makes it askable.
            return screenAskedInEarlierLaunch && hasWalked
        case .systemAudio:
            // Only a probe that heard silence is a refusal; nil means the probe could not run.
            return hasWalked && Permissions.systemAudioProof == false
        case .microphone:
            return hasWalked
        }
    }

    private func render() {
        for permission in JarvisReadiness.Permission.allCases {
            let granted = Permissions.isGranted(permission)
            let isAsking = asking == permission
            let tone: PermissionRowView.Tone = granted ? .granted
                : isBeyondAsking(permission) ? .refused
                : isAsking ? .asking : .needed
            rows[permission]?.render(
                status: statusText(for: permission, granted: granted, asking: isAsking), tone: tone)
        }
        let state = terminalState
        shell?.setPrimary(title: buttonTitle(for: state), enabled: !isRequesting)
        shell?.setNote(footnoteText(for: state), warning: false)
    }

    private func statusText(
        for permission: JarvisReadiness.Permission, granted: Bool, asking: Bool
    ) -> String {
        if granted { return "Granted" }
        if asking { return "Asking…" }
        if isBeyondAsking(permission) { return "Refused" }
        if permission == .screenRecording, hasWalked { return "Reopen to finish" }
        return "Needed"
    }

    private func buttonTitle(for state: TerminalState) -> String {
        if isRequesting { return "Waiting for macOS…" }
        return switch state {
        case .none: "Grant Access"
        case .refused: "Open System Settings"
        case .needsRelaunch: "Quit & Reopen"
        case .satisfied: "I’m Ready"
        }
    }

    private func footnoteText(for state: TerminalState) -> String {
        if isRequesting { return "Answer macOS and I’ll take the next one." }
        return switch state {
        case .none where hasWalked && Permissions.systemAudioProof == nil:
            "I couldn’t check system audio just now. Try again."
        case .none:
            // Empty on purpose: the rows already say what is needed.
            ""
        case .refused(let refused):
            "macOS won’t let me ask twice. Switch "
                + refused.map(\.displayName).joined(separator: " and ")
                + " on by hand and I’ll be ready."
        case .needsRelaunch:
            "Almost there. macOS only shows me screen access in a fresh session, so let me reopen "
                + "and check."
        case .satisfied:
            "That’s everything. I’ll be up in your menu bar whenever you need me."
        }
    }

    // MARK: - List

    private func makeList() -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 1
        card.borderColor = OnboardingTheme.line
        card.fillColor = OnboardingTheme.card
        card.contentViewMargins = .zero
        let permissions = JarvisReadiness.Permission.allCases
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, permission) in permissions.enumerated() {
            let row = PermissionRowView(
                name: permission.displayName, purpose: Self.purpose(of: permission),
                showsSeparator: index > 0)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            // A stack's width alignment is only a low-priority preference.
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows[permission] = row
        }
        card.contentView?.addSubview(stack)
        if let content = card.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        // An NSBox doesn't size itself from its content's constraints.
        card.heightAnchor.constraint(
            equalToConstant: CGFloat(permissions.count) * PermissionRowView.height + 2).isActive = true
        return card
    }

    private static func purpose(of permission: JarvisReadiness.Permission) -> String {
        switch permission {
        case .microphone: "So I can hear your voice"
        case .systemAudio: "So I can hear the other side of your call"
        case .screenRecording: "So I can see what’s on your screen"
        }
    }
}
