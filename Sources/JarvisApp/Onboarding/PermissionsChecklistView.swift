import AppKit
import JarvisCore

// Design: wiki/architecture.md#permissions
@MainActor
final class PermissionsChecklistView: NSView {
    var onFinished: (() -> Void)?
    var onQuit: (() -> Void)?

    private struct Row {
        let permission: JarvisReadiness.Permission
        let glyph: NSTextField
        let name: NSTextField
        let why: NSTextField
        let status: NSTextField
        let separator: NSBox
    }

    private let preferences: PermissionPreferences
    private let titleLabel = NSTextField(
        labelWithString: "Hi, it’s Jarvis. Before we start, I need three things from you.")
    private let footnote = NSTextField(labelWithString: "")
    private var primaryButton = ClosureButton(title: "", action: {})
    private var quitButton = ClosureButton(title: "", action: {})
    private var rows: [Row] = []
    private var isRequesting = false
    private var activationObserver: (any NSObjectProtocol)?
    private var asking: JarvisReadiness.Permission?
    private var sentToSettings: Set<JarvisReadiness.Permission> = []
    private var hasWalked = false
    /// Read at init, before this launch asks: only an earlier, still-missing ask proves refusal.
    private let screenAskedInEarlierLaunch: Bool

    private enum Layout {
        static let inset: CGFloat = 28
        static let rowHeight: CGFloat = 52
        static let titleTop: CGFloat = 30
    }

    init(preferences: PermissionPreferences) {
        self.preferences = preferences
        self.screenAskedInEarlierLaunch = preferences.screenRecordingAsked
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        footnote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byWordWrapping
        footnote.maximumNumberOfLines = 2

        primaryButton = ClosureButton(title: "Grant Access") { [weak self] in self?.primaryAction() }
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"

        quitButton = ClosureButton(title: "Quit") { [weak self] in self?.onQuit?() }
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .large

        rows = JarvisReadiness.Permission.allCases.map(makeRow(for:))

        // Re-render on return from System Settings, so the label matches what a click will do.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRequesting else { return }
                self.render()
            }
        }
        for view in [titleLabel, footnote, quitButton, primaryButton] { addSubview(view) }
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
        guard NSWorkspace.shared.open(url) else { // ghost-mode-allowed: explicit click on the gate
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
        NSWorkspace.shared.openApplication( // ghost-mode-allowed: explicit click on the launch gate
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
        for row in rows {
            let granted = Permissions.isGranted(row.permission)
            let isAsking = asking == row.permission
            row.status.stringValue = statusText(for: row.permission, granted: granted, asking: isAsking)
            row.status.textColor = granted ? .systemGreen
                : (isBeyondAsking(row.permission) ? .systemOrange : .secondaryLabelColor)
            row.glyph.stringValue = granted ? "●" : "○"
            row.glyph.textColor = granted ? .systemGreen : .tertiaryLabelColor
            let recedes = isRequesting && !isAsking
            for label in [row.glyph, row.name, row.why, row.status] {
                label.alphaValue = recedes ? 0.38 : 1
            }
        }

        let state = terminalState
        primaryButton.isEnabled = !isRequesting
        primaryButton.title = buttonTitle(for: state)
        footnote.stringValue = footnoteText(for: state)
        needsLayout = true
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

    // MARK: - Rows

    private func makeRow(for permission: JarvisReadiness.Permission) -> Row {
        let glyph = NSTextField(labelWithString: "○")
        glyph.font = .systemFont(ofSize: 13)

        let name = NSTextField(labelWithString: permission.displayName)
        name.font = .systemFont(ofSize: 13.5, weight: .medium)

        let why = NSTextField(labelWithString: Self.purpose(of: permission))
        why.font = .systemFont(ofSize: 11.5)
        why.textColor = .tertiaryLabelColor
        why.lineBreakMode = .byTruncatingTail

        let status = NSTextField(labelWithString: "Needed")
        status.font = .systemFont(ofSize: 11.5)
        status.alignment = .right

        let separator = NSBox()
        separator.boxType = .separator
        separator.isHidden = permission == JarvisReadiness.Permission.allCases.first

        for view in [glyph, name, why, status, separator] { addSubview(view) }
        return Row(permission: permission, glyph: glyph, name: name, why: why,
                   status: status, separator: separator)
    }

    private static func purpose(of permission: JarvisReadiness.Permission) -> String {
        switch permission {
        case .microphone: "So I can hear your voice"
        case .systemAudio: "So I can hear the other side of your call"
        case .screenRecording: "So I can see what’s on your screen"
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let inset = Layout.inset
        let width = bounds.width - inset * 2
        var top = bounds.height - Layout.titleTop

        let titleHeight = ceil(titleLabel.sizeThatFits(
            NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        top -= titleHeight
        titleLabel.frame = NSRect(x: inset, y: top, width: width, height: titleHeight)
        top -= 24

        for row in rows {
            row.separator.frame = NSRect(x: inset, y: top, width: width, height: 1)
            top -= Layout.rowHeight
            let textLeft = inset + 26
            row.glyph.frame = NSRect(x: inset, y: top + 18, width: 18, height: 16)
            row.name.frame = NSRect(x: textLeft, y: top + 25, width: width - 160, height: 17)
            row.why.frame = NSRect(x: textLeft, y: top + 9, width: width - 160, height: 15)
            row.status.frame = NSRect(x: bounds.width - inset - 130, y: top + 18,
                                      width: 130, height: 16)
        }

        // The note gets its own line: the longest one wraps to two full-width lines.
        let buttonWidth: CGFloat = 190
        let quitWidth: CGFloat = 74
        primaryButton.frame = NSRect(x: bounds.width - inset - buttonWidth, y: inset,
                                     width: buttonWidth, height: 32)
        quitButton.frame = NSRect(x: primaryButton.frame.minX - quitWidth - 8, y: inset,
                                  width: quitWidth, height: 32)
        footnote.frame = NSRect(x: inset, y: inset + 32 + 10, width: width, height: 34)
    }
}
