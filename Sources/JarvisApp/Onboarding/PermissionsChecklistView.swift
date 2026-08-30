import AppKit
import JarvisCore

/// The permission checklist: one row per macOS grant Jarvis needs, and one button that walks them.
///
/// Shared by the first-launch window and the Settings tab so both show the same state and offer the
/// same recovery. The walk is strictly sequential — macOS queues TCC dialogs, and asking for three
/// at once stacks them into a pile the user can't tell apart.
@MainActor
final class PermissionsChecklistView: NSView {
    /// Fires whenever a row's state changes, so a host can refresh its own controls.
    var onStateChange: (() -> Void)?

    /// Every permission is granted, as far as macOS will tell us.
    var isComplete: Bool {
        JarvisReadiness.Permission.allCases.allSatisfy {
            Permissions.isGranted($0, remembering: preferences)
        }
    }

    static let preferredHeight = SettingsStyle.cardHeaderHeight
        + SettingsStyle.rowHeight * CGFloat(JarvisReadiness.Permission.allCases.count) + 84

    private struct Row {
        let permission: JarvisReadiness.Permission
        let view: SettingsRowView
        let status: NSTextField
        let button: ClosureButton
    }

    private let preferences: PermissionPreferences
    private let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
    private var rows: [Row] = []
    private var primaryButton = ClosureButton(title: "", action: {})
    private let footnote = NSTextField(labelWithString: "")
    /// Permissions this view has already asked macOS for. macOS never re-prompts after a refusal,
    /// so their row switches from asking to pointing at System Settings.
    private var attempted: Set<JarvisReadiness.Permission> = []
    private var isRequesting = false

    init(preferences: PermissionPreferences) {
        self.preferences = preferences
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: Self.preferredHeight))
        autoresizingMask = [.width]

        card.setHeader(title: "Permissions", detail: "Granted once, in System Settings")
        rows = JarvisReadiness.Permission.allCases.map(makeRow(for:))

        primaryButton = ClosureButton(title: "Grant Permissions") { [weak self] in
            self?.requestAll()
        }
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"

        footnote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byWordWrapping
        footnote.maximumNumberOfLines = 2

        for row in rows { card.contentView?.addSubview(row.view) }
        addSubview(card)
        addSubview(primaryButton)
        addSubview(footnote)
        card.onLayout = { [weak self] in self?.layoutRows() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Re-reads every grant. A host calls this when it becomes visible again, since the user may
    /// have changed a switch in System Settings while Jarvis was running.
    func refresh() {
        render()
    }

    // MARK: - Requesting

    /// Asks for every outstanding grant, one dialog at a time, in checklist order.
    private func requestAll() {
        guard !isRequesting else { return }
        isRequesting = true
        render()
        Task { @MainActor in
            for permission in JarvisReadiness.Permission.allCases
            where !Permissions.isGranted(permission, remembering: preferences) {
                attempted.insert(permission)
                _ = await Permissions.request(permission, remembering: preferences)
                render()
            }
            isRequesting = false
            render()
        }
    }

    private func request(_ permission: JarvisReadiness.Permission) {
        guard !isRequesting else { return }
        guard !attempted.contains(permission) else {
            openSystemSettings(for: permission)
            return
        }
        isRequesting = true
        attempted.insert(permission)
        render()
        Task { @MainActor in
            _ = await Permissions.request(permission, remembering: preferences)
            isRequesting = false
            render()
        }
    }

    /// Once a user has refused, macOS answers for them without prompting, so the settings pane is
    /// the only way back.
    private func openSystemSettings(for permission: JarvisReadiness.Permission) {
        // Screen Recording and System Audio Recording share one pane from macOS 15 on.
        let anchor = switch permission {
        case .microphone: "Privacy_Microphone"
        case .systemAudio, .screenRecording: "Privacy_ScreenCapture"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url) // ghost-mode-allowed: explicit click on a permission row
    }

    // MARK: - Rendering

    private func render() {
        for row in rows {
            let granted = Permissions.isGranted(row.permission, remembering: preferences)
            row.status.stringValue = granted ? "Granted" : "Needed"
            row.status.textColor = granted ? .systemGreen : .secondaryLabelColor
            row.button.isHidden = granted
            row.button.isEnabled = !isRequesting
            row.button.title = attempted.contains(row.permission) ? "Open Settings" : "Grant"
        }
        primaryButton.isHidden = isComplete
        primaryButton.isEnabled = !isRequesting
        primaryButton.title = isRequesting ? "Waiting for macOS…" : "Grant Permissions"
        footnote.stringValue = footnoteText
        needsLayout = true
        onStateChange?()
    }

    private var footnoteText: String {
        if isComplete { return "All set — Jarvis has everything it needs." }
        // A Screen Recording grant is only visible to a new process, so the row stays "Needed"
        // however the user answered. Saying so is the difference between finishing and retrying.
        if attempted.contains(.screenRecording),
           !Permissions.isGranted(.screenRecording, remembering: preferences) {
            return "Screen Recording only takes effect in a new process — quit Jarvis and open it "
                + "again to finish."
        }
        return "Granting these now means no macOS prompt interrupts a session later."
    }

    private func makeRow(for permission: JarvisReadiness.Permission) -> Row {
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.alignment = .right

        let button = ClosureButton(title: "Grant") { [weak self] in self?.request(permission) }
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("Grant \(permission.displayName)")

        let control = NSStackView(views: [status, button])
        control.orientation = .horizontal
        control.spacing = 10
        control.alignment = .centerY

        let view = SettingsRowView(
            title: permission.displayName,
            detail: Self.purpose(of: permission),
            controlView: control,
            controlSize: NSSize(width: 190, height: 32),
            showsSeparator: permission != JarvisReadiness.Permission.allCases.last)
        return Row(permission: permission, view: view, status: status, button: button)
    }

    private static func purpose(of permission: JarvisReadiness.Permission) -> String {
        switch permission {
        case .microphone: "Hear you think aloud"
        case .systemAudio: "Hear the other side of your call"
        case .screenRecording: "Read your screen when the coach needs context"
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let cardHeight = SettingsStyle.cardHeaderHeight
            + SettingsStyle.rowHeight * CGFloat(rows.count)
        card.frame = NSRect(x: 0, y: bounds.height - cardHeight,
                            width: bounds.width, height: cardHeight)
        layoutRows()

        let buttonWidth: CGFloat = 170
        primaryButton.frame = NSRect(x: bounds.width - buttonWidth, y: card.frame.minY - 44,
                                     width: buttonWidth, height: 32)
        footnote.frame = NSRect(x: 0, y: card.frame.minY - 48,
                                width: max(120, bounds.width - buttonWidth - 16), height: 36)
    }

    private func layoutRows() {
        guard let content = card.contentView else { return }
        var top = content.bounds.height - SettingsStyle.cardHeaderHeight
        for row in rows {
            top -= SettingsStyle.rowHeight
            row.view.frame = NSRect(x: 0, y: top,
                                    width: content.bounds.width, height: SettingsStyle.rowHeight)
        }
    }
}
