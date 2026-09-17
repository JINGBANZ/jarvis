import AppKit
import JarvisCore

/// Settings → Eye: what the coach screenshots when `capture_screen` fires.
@MainActor
final class DisplaySection: NSObject, SettingsSection {
    let destination = SettingsDestination.eye

    private let preferences: ScreenCapturePreferences
    /// Called after an edit is persisted so the host can freeze a fresh control-plane revision for
    /// the next attempt. A turn already running keeps the revision it snapshotted.
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

    func makePage() -> SettingsPageView {
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
        card.setHeader(title: "Screen capture")
        let row = SettingsRowView(
            title: "What I capture",
            detail: "The window you last clicked or typed in.",
            controlView: popup,
            controlSize: NSSize(width: 300, height: 32),
            preferredHeight: 64,
            showsSeparator: true)
        let browserTextRow = SettingsRowView(
            title: "Read Chrome page text",
            detail: "Needs Accessibility permission. You can switch it on only while I'm stopped.",
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

        let callout = SettingsCalloutView(text: "I skip my own windows. If nothing fits, I capture your "
            + "main display instead. Screenshots stay in this Mac's session folder.")
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
            callout.heightAnchor.constraint(equalToConstant: SettingsCalloutView.preferredHeight),
        ])

        return SettingsPageView(
            title: "Eye",
            summary: "What I look at when I check your screen.",
            chip: .neutral("Applies next capture"),
            part: .eye,
            bodyView: body)
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

    /// Row 0 is the active-window scope; on rows 1…n the row number is the display's
    /// `screencapture -D` index.
    private func reloadItems() {
        guard let popup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Active window (recommended)")
        popup.addItems(withTitles: NSScreen.displayTitles.map { "Entire display: \($0)" })
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
        // Turning access off is immediate and cannot expose more data. Enabling remains a stopped-
        // session operation because it may present macOS privacy UI.
        browserTextSwitch.isEnabled = isSessionStopped() || preferences.browserTextEnabled
        // The reconcile above switches page text off without a live grant, so On implies one.
        browserTextSwitch.toolTip = preferences.browserTextEnabled
            ? "On for the Chrome tab in front"
            : "Off. I read the window's text from the screenshot."
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
        // A request may be denied or deferred to System Settings. Persist only a live grant so the
        // switch never claims that unavailable page text is enabled.
        preferences.browserTextEnabled = BrowserAccessibilityPermission.isGranted
        onChange()
        reloadBrowserTextControl()
    }
}
