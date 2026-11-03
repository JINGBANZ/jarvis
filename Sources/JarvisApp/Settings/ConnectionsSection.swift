import AppKit
import JarvisCore
import JarvisBrainProviders

@MainActor
final class ConnectionsSection: NSObject, SettingsSection {
    let destination = SettingsDestination.connections

    private static let credentialOrder: [Credential] = [.openAIAPIKey, .geminiAPIKey, .deepgramAPIKey]

    private let apiKeyControls: [Credential: APIKeyControls]
    private let subscriptions: SubscriptionControls
    private let signIns: SubscriptionSignIns
    private var pageView: SettingsPageView?
    private var stack: SettingsCardStack?
    private var apiKeyCard: SettingsCardView?
    private var subscriptionsCard: NSView?

    init(
        keyStore: FileSecretStore,
        signIns: SubscriptionSignIns,
        onKeySaved: @escaping (Credential, String) -> Void,
        onSubscriptionWillSignOut: @escaping (BrainProvider) -> Void
    ) {
        self.apiKeyControls = Dictionary(uniqueKeysWithValues: Self.credentialOrder.map { credential in
            (credential, APIKeyControls(credential: credential, store: keyStore, onKeySaved: onKeySaved))
        })
        self.subscriptions = SubscriptionControls(signIns: signIns)
        self.signIns = signIns
        super.init()
        subscriptions.onWillSignOut = onSubscriptionWillSignOut
        subscriptions.onStatusChanged = { [weak self] in self?.renderPageStatus() }
    }

    func makePage() -> SettingsPageView {
        let stack = SettingsCardStack()
        self.stack = stack
        let apiKeyCard = makeAPIKeyCard()
        let subscriptionsCard = subscriptions.makeView { [weak self] height in
            guard let self, let card = self.subscriptionsCard else { return }
            self.stack?.setHeight(height, for: card)
        }
        self.subscriptionsCard = subscriptionsCard
        stack.install([
            (apiKeyCard, apiKeyCardHeight),
            (subscriptionsCard, subscriptions.preferredHeight),
        ])

        let page = SettingsPageView(
            title: "Connections",
            summary: "The accounts and keys I use.",
            bodyView: stack.scrollView)
        pageView = page
        renderPageStatus()
        return page
    }

    func didBecomeActive() {
        signIns.refresh(checkingEmptyAccounts: true)
    }

    func windowWillClose() {
        subscriptions.windowWillClose()
        for controls in apiKeyControls.values { controls.windowWillClose() }
        pageView = nil
        stack = nil
        apiKeyCard = nil
        subscriptionsCard = nil
    }

    private var apiKeyCardHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + apiKeyControls.values.reduce(0) { $0 + $1.preferredHeight }
    }

    private func makeAPIKeyCard() -> SettingsCardView {
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: apiKeyCardHeight))
        card.setHeader(title: "BYOK", detail: "Bring your own API keys")
        apiKeyCard = card
        for (index, credential) in Self.credentialOrder.enumerated() {
            guard let controls = apiKeyControls[credential] else { continue }
            let row = controls.makeView(showsSeparator: index > 0) { [weak self] _ in
                guard let self, let card = self.apiKeyCard else { return }
                self.stack?.setHeight(self.apiKeyCardHeight, for: card)
                self.renderPageStatus()
            }
            card.contentView?.addSubview(row)
        }
        card.onLayout = { [weak self] in self?.layoutAPIKeyRows() }
        return card
    }

    private func layoutAPIKeyRows() {
        guard let card = apiKeyCard else { return }
        let body = card.bodyFrame
        var top = body.maxY
        for credential in Self.credentialOrder {
            guard let controls = apiKeyControls[credential] else { continue }
            top -= controls.preferredHeight
            controls.layout(in: NSRect(
                x: body.minX, y: top, width: body.width, height: controls.preferredHeight))
        }
    }

    private func renderPageStatus() {
        let savedKeyCount = apiKeyControls.values.filter(\.hasSavedKey).count
        pageView?.setChip(.live("\(savedKeyCount) \(savedKeyCount == 1 ? "key" : "keys") saved"))
    }
}
