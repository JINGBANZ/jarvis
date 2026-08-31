import AppKit
import JarvisCore

/// The permission gate's contents: a plain list of the grants Jarvis needs, and the one button that
/// walks them.
///
/// One button, never a row of them. It asks for every outstanding grant in checklist order, strictly
/// one dialog at a time — macOS queues TCC dialogs, and asking for three at once stacks them into a
/// pile the user can't tell apart. Its label is the only thing that changes as the walk progresses,
/// ending on whatever is actually true: reopen, fix in System Settings, or start using Jarvis.
@MainActor
final class PermissionsChecklistView: NSView {
    /// The user is through the gate: every grant is held and they've asked to get on with it.
    var onFinished: (() -> Void)?
    /// The user is leaving without granting. There is no Jarvis to fall back to, so this is a quit.
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
    /// The permission being asked about right now, so the other rows can recede.
    private var asking: JarvisReadiness.Permission?
    /// Whether the walk has run. Until it has, a not-yet-granted permission reads as pending rather
    /// than refused.
    private var hasWalked = false
    /// Whether an *earlier* launch already asked for Screen Recording. Captured once at init: a
    /// grant made in a previous process would be visible to this one, so "asked before and still
    /// missing" is the only proof of refusal macOS leaves. Without it, a refusal is indistinguishable
    /// from a grant awaiting relaunch, and the gate loops the user through Quit & Reopen forever.
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

        // Leaving is a quit, not a dismissal: nothing of Jarvis is running behind this window.
        quitButton = ClosureButton(title: "Quit") { [weak self] in self?.onQuit?() }
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .large

        rows = JarvisReadiness.Permission.allCases.map(makeRow(for:))

        // Returning from System Settings changes what a click will do, and `primaryAction` reads
        // that live. Without this the label keeps the last walk's text, so a button saying "Open
        // System Settings" could quietly start Jarvis instead.
        NotificationCenter.default.addObserver(
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

    /// Asks for every outstanding grant, one dialog at a time, in checklist order.
    private func requestAll() {
        isRequesting = true
        render()
        Task { @MainActor in
            for permission in JarvisReadiness.Permission.allCases
            where !Permissions.isGranted(permission, remembering: preferences) {
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

    /// A refusal is not always final: the user may have just switched the toggle on in System
    /// Settings and come back. Microphone is read live and Screen Recording has its relaunch, but
    /// System Audio Recording has neither, so it is re-proved here before the user is sent back to
    /// a pane where the toggle may already be on. A granted tap answers without a dialog.
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

    /// macOS answers a refusal without prompting again, so the settings pane is the only way back.
    private func openSystemSettings(for permissions: [JarvisReadiness.Permission]) {
        // Screen Recording and System Audio Recording share one pane from macOS 15 on.
        let anchor = switch permissions.first {
        case .microphone: "Privacy_Microphone"
        default: "Privacy_ScreenCapture"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url) // ghost-mode-allowed: explicit click on the permission gate
    }

    /// A fresh Screen Recording grant is only visible to a new process. Safe to do from here and
    /// nowhere else: the gate runs at launch, so there is no session to kill.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication( // ghost-mode-allowed: explicit click on the launch gate
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
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
            !Permissions.isGranted($0, remembering: preferences)
        }
        guard !missing.isEmpty else { return .satisfied }

        let refused = missing.filter(isBeyondAsking)
        // Screen Recording can't be re-asked usefully once this launch has tried: macOS has the
        // answer and won't share it until a new process. Everything else outstanding is still worth
        // a dialog, and asking comes before reporting.
        let askable = missing.filter {
            !refused.contains($0) && !($0 == .screenRecording && hasWalked)
        }
        if !askable.isEmpty { return .none }
        if !refused.isEmpty { return .refused(refused) }
        return .needsRelaunch
    }

    /// Whether macOS has already given its final answer for this permission, so asking again would
    /// be a silent no-op and the only way forward is System Settings.
    private func isBeyondAsking(_ permission: JarvisReadiness.Permission) -> Bool {
        permission == .screenRecording ? screenAskedInEarlierLaunch : hasWalked
    }

    private func render() {
        for row in rows {
            let granted = Permissions.isGranted(row.permission, remembering: preferences)
            let isAsking = asking == row.permission
            row.status.stringValue = statusText(for: row.permission, granted: granted, asking: isAsking)
            row.status.textColor = granted ? .systemGreen
                : (isBeyondAsking(row.permission) ? .systemOrange : .secondaryLabelColor)
            row.glyph.stringValue = granted ? "●" : "○"
            row.glyph.textColor = granted ? .systemGreen : .tertiaryLabelColor
            // Only the row being asked about stays at full strength during the walk.
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
        // Asked this launch and still unreadable: that is Screen Recording waiting for a new process.
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
        case .none:
            // The rows already say what is being asked for; a line restating it is noise.
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

        // Jarvis introduces itself in a sentence, so the title takes the height it needs rather
        // than a fixed line.
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

        // Buttons on the bottom row, the note on its own line above them: the longest note runs to
        // two full-width lines and would truncate if it had to share the row.
        let buttonWidth: CGFloat = 190
        let quitWidth: CGFloat = 74
        primaryButton.frame = NSRect(x: bounds.width - inset - buttonWidth, y: inset,
                                     width: buttonWidth, height: 32)
        quitButton.frame = NSRect(x: primaryButton.frame.minX - quitWidth - 8, y: inset,
                                  width: quitWidth, height: 32)
        footnote.frame = NSRect(x: inset, y: inset + 32 + 10, width: width, height: 34)
    }
}
