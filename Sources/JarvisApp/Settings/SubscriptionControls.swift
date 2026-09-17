import AppKit
import JarvisBrainProviders
import JarvisCore

@MainActor
final class SubscriptionControls: NSObject {
    static let providers: [BrainProvider] = [.codexSubscription, .claudeSubscription]

    let preferredHeight = SettingsStyle.cardHeaderHeight
        + CGFloat(SubscriptionControls.providers.count) * SettingsStyle.rowHeight

    private struct Row {
        let view: SettingsRowView
        let button: NSButton
    }

    private let supervisor: LocalProxySupervisor
    private var rows: [BrainProvider: Row] = [:]
    private var readiness: LocalProxySupervisor.Readiness?
    private var refreshTask: Task<Void, Never>?
    private var signIns: [BrainProvider: Task<Void, Never>] = [:]
    private var actionFailures: [BrainProvider: String] = [:]
    var onStatusChanged: (() -> Void)?

    /// Fires only for this card's own probe answers: an answer replayed when the page is rebuilt
    /// could be older than a check already under way elsewhere.
    var onProbeAnswered: ((LocalProxySupervisor.Readiness) -> Void)?

    /// Subscriptions the last probe proved signed in; `nil` before the first probe answers.
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
            let button = NSButton(title: "Sign in", target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("\(provider.rawValue)-action")

            let controls = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(greaterThanOrEqualTo: controls.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            ])
            let row = SettingsRowView(
                title: provider.displayName,
                detail: "Checking…",
                controlView: controls,
                controlSize: NSSize(width: 240, height: 32),
                showsSeparator: index > 0)
            content.addSubview(row)
            rows[provider] = Row(view: row, button: button)
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

    /// Also starts the helper if it isn't running, which is how a stopped helper is retried.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, supervisor] in
            let readiness = await supervisor.readiness()
            // A sign-in or sign-out that finished meanwhile cleared this task and started its own
            // probe; this stale answer must not paint over it.
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
        // Sign-ins outlive the window on purpose: cancelling one signals the login holding the
        // OAuth callback port, so the browser's redirect would land on nothing.
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
            // A probe started before this sign-in is stale, and while it holds the gate `refresh()`
            // won't start a new one.
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
            // Redacted: the message quotes the credential's path, which contains the account's
            // email.
            actionFailures[provider] = "Sign-out failed: "
                + ProviderMessageRedaction.redact(error.localizedDescription)
        }
        readiness = nil
        // A probe still in flight answers for the credential just removed.
        refreshTask?.cancel()
        refreshTask = nil
        render()
        refresh()
    }

    private func render() {
        for provider in Self.providers {
            guard let row = rows[provider] else { continue }
            let presentation = presentation(for: provider)
            row.button.title = presentation.button
            row.button.isEnabled = presentation.buttonEnabled
            row.button.setAccessibilityLabel("\(presentation.button) \(provider.displayName)")
            if let failure = actionFailures[provider] {
                row.view.setDetail(failure, color: SettingsTheme.amber)
            } else {
                row.view.setDetail(presentation.status, color: presentation.color)
            }
        }
        onStatusChanged?()
    }

    private func presentation(for provider: BrainProvider) -> (
        status: String, color: NSColor, button: String, buttonEnabled: Bool
    ) {
        if signIns[provider] != nil {
            return ("Signing in. Finish in your browser.", SettingsTheme.mutedText, "Cancel", true)
        }
        guard let readiness else {
            return ("Checking…", SettingsTheme.mutedText, "Sign in", false)
        }
        let account = supervisor.accountFiles(for: provider).first
        let who = account.map { file in
            [file.email, file.plan].compactMap { $0 }.joined(separator: " · ")
        }.flatMap { $0.isEmpty ? nil : $0 }
        switch readiness {
        case .unavailable(let reason):
            return ("Not running. The sign-in service \(reason)", SettingsTheme.amber, "Try again", true)
        case .ready(_, let signedIn) where signedIn.contains(provider):
            return (["Signed in", who].compactMap { $0 }.joined(separator: " · "),
                    SettingsTheme.teal, "Sign out", true)
        case .ready where account != nil:
            return ("Not usable. \(who.map { "\($0) is" } ?? "The account is") saved but can't be used "
                        + "right now, so sign in again.",
                    SettingsTheme.amber, "Sign in", true)
        case .ready:
            return ("Signed out. \(Self.accountHint(provider)).", SettingsTheme.mutedText, "Sign in", true)
        }
    }

    private static func accountHint(_ provider: BrainProvider) -> String {
        provider == .codexSubscription
            ? "Signs in with your ChatGPT account"
            : "Signs in with your Claude account"
    }
}
