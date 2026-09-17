import AppKit
import JarvisBrainProviders
import JarvisCore

/// The Subscriptions card in Connections: one row per subscription target, signed in and out
/// through the helper bundled in Jarvis.app. A row reads the helper's state, its credential files,
/// and one model-list probe per refresh, so what it says is what a Start would find.
@MainActor
final class SubscriptionControls: NSObject {
    static let providers: [BrainProvider] = [.codexSubscription, .claudeSubscription]

    let preferredHeight = SettingsStyle.cardHeaderHeight
        + CGFloat(SubscriptionControls.providers.count) * SettingsStyle.rowHeight

    private struct Row {
        let view: SettingsRowView
        let status: NSTextField
        let button: NSButton
    }

    private let supervisor: LocalProxySupervisor
    private var rows: [BrainProvider: Row] = [:]
    private var readiness: LocalProxySupervisor.Readiness?
    private var refreshTask: Task<Void, Never>?
    private var signIns: [BrainProvider: Task<Void, Never>] = [:]
    /// The last failed action's row detail, in that action's own words. Pressing either button
    /// clears it, so a message never outlives the state it described.
    private var actionFailures: [BrainProvider: String] = [:]
    /// Called whenever a row changes, so the page badge can recount.
    var onStatusChanged: (() -> Void)?

    /// Called with each answer a probe of this card brings back, and only then: a stored answer
    /// replayed when the page is rebuilt would be older than a check already under way elsewhere.
    var onProbeAnswered: ((LocalProxySupervisor.Readiness) -> Void)?

    /// Subscriptions the last probe proved signed in; nil before the first probe answers.
    var signedIn: Set<BrainProvider>? {
        switch readiness {
        case .ready(_, let signedIn): signedIn
        case .unavailable: []
        case nil: nil
        }
    }

    init(supervisor: LocalProxySupervisor) {
        self.supervisor = supervisor
    }

    func makeView() -> NSView {
        rows.removeAll()
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.setHeader(title: "Subscriptions", detail: "Use your ChatGPT or Claude plan as my brain")
        guard let content = card.contentView else { return card }

        for (index, provider) in Self.providers.enumerated() {
            let status = NSTextField(labelWithString: "Checking…")
            status.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            status.alignment = .right
            status.textColor = SettingsTheme.mutedText
            let button = NSButton(title: "Sign in", target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("\(provider.rawValue)-action")

            let trailing = NSStackView(views: [status, button])
            trailing.orientation = .horizontal
            trailing.alignment = .centerY
            trailing.spacing = 8
            status.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
            let controls = NSView()
            trailing.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(trailing)
            NSLayoutConstraint.activate([
                trailing.leadingAnchor.constraint(greaterThanOrEqualTo: controls.leadingAnchor),
                trailing.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
                trailing.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            ])
            let row = SettingsRowView(
                title: provider.displayName,
                detail: nil,
                controlView: controls,
                controlSize: NSSize(width: 240, height: 32),
                showsSeparator: index > 0)
            content.addSubview(row)
            rows[provider] = Row(view: row, status: status, button: button)
        }
        card.onLayout = { [weak self, weak card] in
            guard let self, let card else { return }
            let body = card.bodyFrame
            for (index, provider) in Self.providers.enumerated() {
                rows[provider]?.view.frame = NSRect(
                    x: body.minX,
                    y: body.maxY - CGFloat(index + 1) * SettingsStyle.rowHeight,
                    width: body.width,
                    height: SettingsStyle.rowHeight)
            }
        }
        card.onLayout?()
        render()
        return card
    }

    /// Probe again: the helper starts if it is not running, which is also how a stopped helper is
    /// retried.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, supervisor] in
            let readiness = await supervisor.readiness()
            // A sign-out or a sign-in that finished while this probe was in flight already cleared
            // the state and started its own; a stale answer would paint over it.
            guard !Task.isCancelled, let self, refreshTask != nil else { return }
            self.readiness = readiness
            refreshTask = nil
            onProbeAnswered?(readiness)
            render()
        }
    }

    func windowWillClose() {
        refreshTask?.cancel()
        refreshTask = nil
        // A sign-in outlives this window. Cancelling it here would signal the login holding the
        // OAuth callback port, so the browser's redirect would land on nothing and the row would
        // read "Signed out" for a sign-in the user never cancelled. Cancel ends it, and so does Quit.
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard Self.providers.indices.contains(sender.tag) else { return }
        let provider = Self.providers[sender.tag]
        if let signIn = signIns[provider] {
            signIn.cancel()
            return
        }
        switch readiness {
        case .unavailable:
            refresh()
        case .ready(_, let signedIn) where signedIn.contains(provider):
            signOut(provider)
        case .ready, nil:
            signIn(provider)
        }
    }

    private func signIn(_ provider: BrainProvider) {
        actionFailures[provider] = nil
        signIns[provider] = Task { [weak self, supervisor] in
            var failure: String?
            if let signIn = await supervisor.makeSignIn() {
                for await event in signIn.run(provider) {
                    switch event {
                    case .openURL(let url):
                        NSWorkspace.shared.open(url) // ghost-mode-allowed: the user pressed Sign in inside Settings
                    case .finished:
                        break
                    case .failed(let message):
                        failure = message
                    }
                }
            } else {
                failure = "the sign-in service isn't running"
            }
            guard let self else { return }
            signIns[provider] = nil
            if let failure, !Task.isCancelled {
                actionFailures[provider] = "Sign-in failed: \(ProviderMessageRedaction.redact(failure))"
            }
            readiness = nil
            // A probe started before this sign-in describes the state it replaced, and `refresh()`
            // would otherwise decline to start a new one while that stale task still holds the gate.
            refreshTask?.cancel()
            refreshTask = nil
            render()
            refresh()
        }
        render()
    }

    private func signOut(_ provider: BrainProvider) {
        actionFailures[provider] = nil
        do {
            try supervisor.signOut(provider)
        } catch {
            // Its own verb: this read "Sign-in failed" for a sign-out. The message quotes the
            // credential's path, which carries the account's address, so it takes the same
            // redaction the sign-in message does.
            actionFailures[provider] = "Sign-out failed: "
                + ProviderMessageRedaction.redact(error.localizedDescription)
        }
        readiness = nil
        // The credential is gone; a probe still in flight answers for the account that had it.
        refreshTask?.cancel()
        refreshTask = nil
        render()
        refresh()
    }

    private func render() {
        for provider in Self.providers {
            guard let row = rows[provider] else { continue }
            let presentation = presentation(for: provider)
            row.status.stringValue = presentation.status
            row.status.textColor = presentation.color
            row.status.setAccessibilityLabel("\(provider.displayName): \(presentation.status)")
            row.button.title = presentation.button
            row.button.isEnabled = presentation.buttonEnabled
            row.button.setAccessibilityLabel("\(presentation.button) \(provider.displayName)")
            row.view.setDetail(actionFailures[provider] ?? presentation.detail)
        }
        onStatusChanged?()
    }

    private func presentation(for provider: BrainProvider) -> (
        status: String, color: NSColor, detail: String?, button: String, buttonEnabled: Bool
    ) {
        if signIns[provider] != nil {
            return ("Signing in…", SettingsTheme.mutedText, "Finish in your browser", "Cancel", true)
        }
        guard let readiness else {
            return ("Checking…", SettingsTheme.mutedText, Self.accountHint(provider), "Sign in", false)
        }
        let account = supervisor.accountFiles(for: provider).first
        let who = account.map { file in
            [file.email, file.plan].compactMap { $0 }.joined(separator: " · ")
        }.flatMap { $0.isEmpty ? nil : $0 }
        switch readiness {
        case .unavailable(let reason):
            return ("Not running", SettingsTheme.amber, "The sign-in service \(reason)", "Try again", true)
        case .ready(_, let signedIn) where signedIn.contains(provider):
            return ("Signed in", SettingsTheme.teal, who.map { "As \($0)" }, "Sign out", true)
        case .ready where account != nil:
            return ("Not usable", SettingsTheme.amber,
                    "\(who.map { "\($0) is" } ?? "The account is") saved but not usable right now; sign in again",
                    "Sign in", true)
        case .ready:
            return ("Signed out", SettingsTheme.mutedText, Self.accountHint(provider), "Sign in", true)
        }
    }

    /// A row's title names the coding tool; the sign-in asks for the consumer account that pays for
    /// it, and the two names differ. A signed-in row says who is signed in instead.
    private static func accountHint(_ provider: BrainProvider) -> String {
        provider == .codexSubscription
            ? "Signs in with your ChatGPT account"
            : "Signs in with your Claude account"
    }
}
