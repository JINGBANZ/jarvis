import AppKit
import JarvisCore

@MainActor
final class DisplaySection: NSObject, SettingsSection {
    let title = "Screen"
    let fillsTab = true

    private let preferences: ScreenCapturePreferences
    private let onChange: () -> Void
    private let isSessionStopped: () -> Bool
    private var popup: NSPopUpButton?
    private var browserTextSwitch: NSSwitch?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    init(
        preferences: ScreenCapturePreferences,
        isSessionStopped: @escaping () -> Bool = { true },
        onChange: @escaping () -> Void = {}
    ) {
        self.preferences = preferences
        self.isSessionStopped = isSessionStopped
        self.onChange = onChange
    }

    func makeView() -> NSView {
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 712, height: 432))

        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(scopeChanged)
        popup.setAccessibilityLabel("Capture scope")
        self.popup = popup
        reloadItems()

        let browserTextSwitch = NSSwitch()
        browserTextSwitch.target = self
        browserTextSwitch.action = #selector(browserTextChanged)
        browserTextSwitch.setAccessibilityLabel("Read Chrome page text")
        self.browserTextSwitch = browserTextSwitch
        reloadBrowserTextControl()

        let cardHeight = SettingsStyle.cardHeaderHeight + 128
        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: cardHeight))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setHeader(title: "Screen capture", detail: "Applied to the next coaching turn")
        let row = SettingsRowView(
            title: "Capture scope",
            detail: "Active window is the most private option",
            controlView: popup,
            controlSize: NSSize(width: 300, height: 32),
            preferredHeight: 64,
            showsSeparator: true)
        let browserTextRow = SettingsRowView(
            title: "Read Chrome page text",
            detail: "Optional Accessibility access; may include off-screen text",
            controlView: browserTextSwitch,
            controlSize: NSSize(width: 46, height: 28),
            preferredHeight: 64,
            showsSeparator: false)
        card.contentView?.addSubview(row)
        card.contentView?.addSubview(browserTextRow)
        card.onLayout = { [weak card, weak row, weak browserTextRow] in
            guard let card, let row, let browserTextRow else { return }
            let body = card.bodyFrame
            row.frame = NSRect(x: body.minX, y: body.midY,
                               width: body.width, height: body.height / 2)
            browserTextRow.frame = NSRect(x: body.minX, y: body.minY,
                                          width: body.width, height: body.height / 2)
        }

        let callout = makeCallout()
        callout.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(card)
        body.addSubview(callout)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: body.topAnchor),
            card.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: cardHeight),
            callout.topAnchor.constraint(equalTo: card.bottomAnchor, constant: SettingsStyle.sectionSpacing),
            callout.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            callout.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            callout.heightAnchor.constraint(equalToConstant: 68),
        ])

        return SettingsPageView(
            title: "Screen",
            summary: "Control what Jarvis can see when it needs visual context.",
            bodyView: body)
    }

    private func makeCallout() -> NSBox {
        let callout = NSBox()
        callout.boxType = .custom
        callout.borderWidth = 1
        callout.cornerRadius = 10
        callout.borderColor = NSColor.systemBlue.withAlphaComponent(0.18)
        callout.fillColor = NSColor.systemBlue.withAlphaComponent(0.07)
        callout.contentViewMargins = .zero

        guard let content = callout.contentView else { return callout }
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemBlue
        content.addSubview(icon)

        let note = NSTextField(wrappingLabelWithString:
            "Jarvis captures only when the brain requests visual context. If the active window "
            + "is Chrome, page text is enabled, and permission is available, semantic text is "
            + "added alongside OCR. "
            + "Screenshots still carry images and diagrams.")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            note.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            note.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        return callout
    }

    func didBecomeActive() {
        reloadItems()
        reloadBrowserTextControl()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadItems() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadBrowserTextControl() }
        }
    }

    func didResignActive() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        screenObserver = nil
        activationObserver = nil
    }

    /// Row 0 is the active window; on rows 1…n the row number is the `screencapture -D` index.
    private func reloadItems() {
        guard let popup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Active window (recommended)")
        popup.addItems(withTitles: NSScreen.displayTitles.map { "Entire display — \($0)" })
        switch preferences.scope {
        case .activeWindow:
            popup.selectItem(at: 0)
        case .entireDisplay:
            let stored = preferences.displayIndex
            popup.selectItem(at: stored < popup.numberOfItems
                ? stored
                : min(1, popup.numberOfItems - 1))
        }
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard row >= 0 else { return }
        if row == 0 {
            preferences.scope = .activeWindow
        } else {
            preferences.scope = .entireDisplay
            preferences.displayIndex = row
        }
        onChange()
    }

    private func reloadBrowserTextControl() {
        guard let browserTextSwitch else { return }
        if preferences.reconcileBrowserTextAvailability(
            isAvailable: BrowserAccessibilityPermission.isGranted
        ) {
            onChange()
        }
        browserTextSwitch.state = preferences.browserTextEnabled ? .on : .off
        // Turning off is always allowed. Turning on waits for a stopped session because it may
        // present macOS privacy UI.
        browserTextSwitch.isEnabled = isSessionStopped() || preferences.browserTextEnabled
        if preferences.browserTextEnabled, BrowserAccessibilityPermission.isGranted {
            browserTextSwitch.toolTip = "Enabled for foreground Chrome tabs"
        } else if preferences.browserTextEnabled {
            browserTextSwitch.toolTip = "Accessibility permission is missing; captures use OCR"
        } else {
            browserTextSwitch.toolTip = "Off; captures use current-window OCR"
        }
    }

    @objc private func browserTextChanged(_ sender: NSSwitch) {
        if sender.state == .off {
            preferences.browserTextEnabled = false
            onChange()
            reloadBrowserTextControl()
            return
        }
        guard isSessionStopped() else {
            reloadBrowserTextControl()
            return
        }
        if !BrowserAccessibilityPermission.isGranted {
            BrowserAccessibilityPermission.request()
        }
        // The request may be denied or deferred to System Settings, so persist only a live grant.
        preferences.browserTextEnabled = BrowserAccessibilityPermission.isGranted
        onChange()
        reloadBrowserTextControl()
    }
}
