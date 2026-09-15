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
    private var signInFailures: [BrainProvider: String] = [:]
    /// Called whenever a row changes, so the page badge can recount.
    var onStatusChanged: (() -> Void)?

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
        card.setHeader(title: "Subscriptions", detail: "Sign in once; tokens stay on this Mac")
        guard let content = card.contentView else { return card }

        for (index, provider) in Self.providers.enumerated() {
            let status = NSTextField(labelWithString: "Checking…")
            status.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            status.alignment = .right
            status.textColor = .secondaryLabelColor
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
            guard let self else { return }
            self.readiness = readiness
            refreshTask = nil
            render()
        }
    }

    func windowWillClose() {
        refreshTask?.cancel()
        refreshTask = nil
        for task in signIns.values { task.cancel() }
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
        signInFailures[provider] = nil
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
                signInFailures[provider] = ProviderMessageRedaction.redact(failure)
            }
            readiness = nil
            render()
            refresh()
        }
        render()
    }

    private func signOut(_ provider: BrainProvider) {
        do {
            try supervisor.signOut(provider)
        } catch {
            signInFailures[provider] = "I couldn't remove the saved sign-in: \(error.localizedDescription)"
        }
        readiness = nil
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
            row.view.setDetail(signInFailures[provider].map { "Sign-in failed: \($0)" } ?? presentation.detail)
        }
        onStatusChanged?()
    }

    private func presentation(for provider: BrainProvider) -> (
        status: String, color: NSColor, detail: String?, button: String, buttonEnabled: Bool
    ) {
        if signIns[provider] != nil {
            return ("Signing in…", .secondaryLabelColor, "Finish in your browser", "Cancel", true)
        }
        guard let readiness else {
            return ("Checking…", .secondaryLabelColor, nil, "Sign in", false)
        }
        let account = supervisor.accountFiles(for: provider).first
        let who = account.map { file in
            [file.email, file.plan].compactMap { $0 }.joined(separator: " · ")
        }.flatMap { $0.isEmpty ? nil : $0 }
        switch readiness {
        case .unavailable(let reason):
            return ("Not running", .systemOrange, "The sign-in service \(reason)", "Try again", true)
        case .ready(_, let signedIn) where signedIn.contains(provider):
            return ("Signed in", .systemGreen, who.map { "As \($0)" }, "Sign out", true)
        case .ready where account != nil:
            return ("Not usable", .systemOrange,
                    "\(who.map { "\($0) is" } ?? "The account is") saved but not usable right now; sign in again",
                    "Sign in", true)
        case .ready:
            return ("Signed out", .secondaryLabelColor, nil, "Sign in", true)
        }
    }
}
