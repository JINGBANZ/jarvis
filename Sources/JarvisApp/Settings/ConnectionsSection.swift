import AppKit
import JarvisCore
import JarvisBrainProviders

/// Settings → Connections: shared authentication and provider readiness, kept separate from the
/// pages that use it. Its own sign-in probes also answer `SubscriptionSignIns`, so the hub and the
/// Brain page agree with what this page shows.
@MainActor
final class ConnectionsSection: NSObject, SettingsSection {
    let destination = SettingsDestination.connections

    private static let credentialOrder: [Credential] = [.openAIAPIKey, .geminiAPIKey]

    private let apiKeyControls: [Credential: APIKeyControls]
    private let subscriptions: SubscriptionControls
    private let signIns: SubscriptionSignIns
    private var pageView: SettingsPageView?
    private var stack: SettingsCardStack?
    private var apiKeyCards: [Credential: NSView] = [:]

    init(
        supervisor: LocalProxySupervisor,
        keyStore: FileSecretStore,
        signIns: SubscriptionSignIns,
        onKeySaved: @escaping (Credential, String) -> Void
    ) {
        self.apiKeyControls = Dictionary(uniqueKeysWithValues: Self.credentialOrder.map { credential in
            (credential, APIKeyControls(credential: credential, store: keyStore, onKeySaved: onKeySaved))
        })
        self.subscriptions = SubscriptionControls(supervisor: supervisor)
        self.signIns = signIns
        super.init()
        subscriptions.onStatusChanged = { [weak self] in self?.renderPageStatus() }
        subscriptions.onProbeAnswered = { [weak self] readiness in self?.signIns.record(readiness) }
    }

    func makePage() -> SettingsPageView {
        let stack = SettingsCardStack()
        self.stack = stack
        apiKeyCards.removeAll()
        var cards: [(view: NSView, height: CGFloat)] = []
        for credential in Self.credentialOrder {
            guard let controls = apiKeyControls[credential] else { continue }
            let card = controls.makeView { [weak self] height in
                guard let self, let card = self.apiKeyCards[credential] else { return }
                self.stack?.setHeight(height, for: card)
                self.renderPageStatus()
            }
            apiKeyCards[credential] = card
            cards.append((card, controls.preferredHeight))
        }
        cards.append((subscriptions.makeView(), subscriptions.preferredHeight))
        stack.install(cards)

        let page = SettingsPageView(
            title: "Connections",
            summary: "The accounts and keys I use.",
            bodyView: stack.scrollView)
        pageView = page
        renderPageStatus()
        return page
    }

    func didBecomeActive() {
        subscriptions.refresh()
    }

    func windowWillClose() {
        subscriptions.windowWillClose()
        for controls in apiKeyControls.values { controls.windowWillClose() }
        pageView = nil
        stack = nil
        apiKeyCards.removeAll()
    }

    private func renderPageStatus() {
        guard let signedIn = subscriptions.signedIn else {
            pageView?.setChip(nil)
            return
        }
        let savedKeyCount = apiKeyControls.values.filter(\.hasSavedKey).count
        pageView?.setChip(.live("\(signedIn.count + savedKeyCount) ready"))
    }
}
