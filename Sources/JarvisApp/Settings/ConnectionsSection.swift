import AppKit
import JarvisCore
import JarvisBrainProviders

/// Shared authentication and provider readiness, kept separate from Brain behavior settings.
@MainActor
final class ConnectionsSection: NSObject, SettingsSection {
    let title = "Connections"
    let fillsTab = true

    private static let credentialOrder: [Credential] = [.openAIAPIKey, .geminiAPIKey]

    private let apiKeyControls: [Credential: APIKeyControls]
    private let subscriptions: SubscriptionControls
    private var pageView: SettingsPageView?
    private var scrollView: SettingsScrollView?
    private var documentStack: NSStackView?
    private var apiKeyHeightConstraints: [Credential: NSLayoutConstraint] = [:]

    init(
        supervisor: LocalProxySupervisor,
        keyStore: FileSecretStore,
        onKeySaved: @escaping (Credential, String) -> Void
    ) {
        self.apiKeyControls = Dictionary(uniqueKeysWithValues: Self.credentialOrder.map { credential in
            (credential, APIKeyControls(credential: credential, store: keyStore, onKeySaved: onKeySaved))
        })
        self.subscriptions = SubscriptionControls(supervisor: supervisor)
        super.init()
        subscriptions.onStatusChanged = { [weak self] in self?.renderPageStatus() }
    }

    func makeView() -> NSView {
        let scrollView = SettingsScrollView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        scrollView.autoresizingMask = [.width, .height]
        self.scrollView = scrollView

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = SettingsStyle.sectionSpacing
        stack.autoresizingMask = [.width]
        documentStack = stack

        apiKeyHeightConstraints.removeAll()
        for credential in Self.credentialOrder {
            guard let controls = apiKeyControls[credential] else { continue }
            let card = controls.makeView { [weak self] height in
                self?.apiKeyHeightConstraints[credential]?.constant = height
                self?.recalculateDocumentHeight()
                self?.renderPageStatus()
            }
            card.translatesAutoresizingMaskIntoConstraints = false
            let height = card.heightAnchor.constraint(equalToConstant: controls.preferredHeight)
            height.isActive = true
            apiKeyHeightConstraints[credential] = height
            stack.addArrangedSubview(card)
        }

        let subscriptionsCard = subscriptions.makeView()
        subscriptionsCard.heightAnchor.constraint(
            equalToConstant: subscriptions.preferredHeight).isActive = true
        stack.addArrangedSubview(subscriptionsCard)

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        bottomSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        if let lastCard = stack.arrangedSubviews.last {
            stack.setCustomSpacing(0, after: lastCard)
        }
        stack.addArrangedSubview(bottomSpacer)

        scrollView.documentView = stack
        scrollView.onViewportChanged = { [weak self] in
            self?.recalculateDocumentHeight()
            self?.revealTop()
        }
        recalculateDocumentHeight()
        revealTop()

        let page = SettingsPageView(
            title: "Connections",
            summary: "Manage authentication used by Jarvis services.",
            bodyView: scrollView)
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
    }

    private func renderPageStatus() {
        guard let signedIn = subscriptions.signedIn else {
            pageView?.setStatus(nil)
            return
        }
        let savedKeyCount = apiKeyControls.values.filter(\.hasSavedKey).count
        pageView?.setStatus("\(signedIn.count + savedKeyCount) ready")
    }

    private func recalculateDocumentHeight() {
        guard let stack = documentStack else { return }
        let visibleHeights = Self.credentialOrder.compactMap { apiKeyControls[$0]?.preferredHeight }
            + [subscriptions.preferredHeight]
        let contentHeight = visibleHeights.reduce(0, +)
            + CGFloat(visibleHeights.count - 1) * SettingsStyle.sectionSpacing
        let viewportHeight = scrollView?.contentView.bounds.height ?? 0
        let height = max(contentHeight, viewportHeight)
        let oldHeight = stack.frame.height
        let oldOrigin = scrollView?.contentView.bounds.origin.y ?? 0
        let distanceFromTop = max(0, oldHeight - oldOrigin - viewportHeight)

        stack.frame.size.height = height
        stack.needsLayout = true
        stack.layoutSubtreeIfNeeded()
        if let scrollView {
            scrollView.contentView.scroll(to: NSPoint(
                x: 0, y: max(0, height - viewportHeight - distanceFromTop)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func revealTop() {
        guard let scrollView, let stack = documentStack else { return }
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(0, stack.bounds.height - scrollView.contentView.bounds.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
