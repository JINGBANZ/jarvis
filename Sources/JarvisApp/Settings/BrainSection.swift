import AppKit
import JarvisCore
import JarvisBrainProviders

/// Minimal Brain Settings surface: one provider route, one reasoning-effort row, and transcription.
///
/// Provider/model ordering is edited by `ProviderRouteEditor`; shared authentication lives in the
/// Connections tab. This section composes behavior controls, refreshes which subscriptions are signed
/// in, and hands completed preference edits to the running session.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    enum PreferenceChange: Equatable {
        case topology
        case effort
    }

    let title = "Brain"
    let fillsTab = true

    private static let coachingCardHeight =
        SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight

    private let preferences: BrainPreferences
    private let supervisor: LocalProxySupervisor
    private let onPreferencesChanged: (PreferenceChange) -> Void
    private let capabilities: CapabilitiesControls
    private let transcription: TranscriptionControls

    private var pageView: SettingsPageView?
    private var scrollView: SettingsScrollView?
    private var documentStack: NSStackView?
    private var providerEditor: ProviderRouteEditor?
    private var providerHeightConstraint: NSLayoutConstraint?
    private var transcriptionHeightConstraint: NSLayoutConstraint?
    /// Subscriptions the helper proved signed in on the latest probe; a subscription can be chosen
    /// only when it is here. Nil until the first probe answers.
    private var signedInSubscriptions: Set<BrainProvider>?
    private var signInTask: Task<Void, Never>?
    /// Session-local runtime state only. This marker never writes preferences or reorders the route.
    private var activeTarget: BrainTarget?

    init(
        preferences: BrainPreferences,
        supervisor: LocalProxySupervisor,
        onPreferencesChanged: @escaping (PreferenceChange) -> Void,
        transcriptionPreferences: TranscriptionPreferences,
        prepMaterialPreferences: PrepMaterialPreferences
    ) {
        self.preferences = preferences
        self.supervisor = supervisor
        self.onPreferencesChanged = onPreferencesChanged
        self.capabilities = CapabilitiesControls(
            preferences: preferences, prepMaterialPreferences: prepMaterialPreferences)
        self.transcription = TranscriptionControls(preferences: transcriptionPreferences)
    }

    func makeView() -> NSView {
        let scrollView = SettingsScrollView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        scrollView.autoresizingMask = [.width, .height]

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = SettingsStyle.sectionSpacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.autoresizingMask = [.width]
        self.scrollView = scrollView
        self.documentStack = stack

        let providerEditor = ProviderRouteEditor(
            preferences: preferences,
            onChange: { [weak self] in self?.onPreferencesChanged(.topology) },
            onHeightChanged: { [weak self] height in
                self?.providerHeightConstraint?.constant = height
                self?.recalculateDocumentHeight()
            })
        providerEditor.view.translatesAutoresizingMaskIntoConstraints = false
        let providerHeight = providerEditor.view.heightAnchor.constraint(
            equalToConstant: providerEditor.preferredHeight)
        providerHeight.isActive = true
        providerHeightConstraint = providerHeight
        stack.addArrangedSubview(providerEditor.view)
        self.providerEditor = providerEditor

        let reasoningCard = makeReasoningCard()
        reasoningCard.heightAnchor.constraint(
            equalToConstant: Self.coachingCardHeight).isActive = true
        stack.addArrangedSubview(reasoningCard)

        let capabilitiesCard = capabilities.makeView()
        capabilitiesCard.heightAnchor.constraint(
            equalToConstant: capabilities.preferredHeight).isActive = true
        stack.addArrangedSubview(capabilitiesCard)

        let transcriptionCard = transcription.makeView { [weak self] height in
            self?.transcriptionHeightConstraint?.constant = height
            self?.recalculateDocumentHeight()
        }
        transcriptionCard.translatesAutoresizingMaskIntoConstraints = false
        let transcriptionHeight = transcriptionCard.heightAnchor.constraint(
            equalToConstant: transcription.preferredHeight)
        transcriptionHeight.isActive = true
        transcriptionHeightConstraint = transcriptionHeight
        stack.addArrangedSubview(transcriptionCard)

        // When the cards are shorter than the viewport, this flexible tail absorbs the remaining
        // height below them. Without it, AppKit anchors the short document at the bottom and leaves
        // a large empty band above Provider.
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        bottomSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        stack.setCustomSpacing(0, after: transcriptionCard)
        stack.addArrangedSubview(bottomSpacer)

        // Attach only after every fixed-height card and the flexible tail exist. Attaching the
        // partially assembled stack makes AppKit briefly solve an impossible intermediate layout.
        scrollView.documentView = stack
        scrollView.onViewportChanged = { [weak self] in
            self?.recalculateDocumentHeight()
            self?.revealTop()
        }
        renderRoute()
        recalculateDocumentHeight()
        revealTop()
        let page = SettingsPageView(
            title: "Brain",
            summary: "Choose how Jarvis thinks, reasons, and transcribes.",
            status: activeTarget.map { "\($0.provider.displayName) in use" },
            bodyView: scrollView)
        pageView = page
        return page
    }

    /// Reflect the driver's selected runtime target without mutating the saved route.
    func setActiveTarget(_ target: BrainTarget?) {
        activeTarget = target
        pageView?.setStatus(target.map { "\($0.provider.displayName) in use" })
        renderRoute()
    }

    func didBecomeActive() {
        refreshSignIns()
    }

    private func makeReasoningCard() -> SettingsCardView {
        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: Self.coachingCardHeight))
        card.setHeader(title: "Coaching", detail: "Response behavior")
        guard let content = card.contentView else { return card }

        let effortPopup = NSPopUpButton()
        effortPopup.addItems(withTitles: ReasoningEffort.allCases.map(\.displayName))
        effortPopup.target = self
        effortPopup.action = #selector(effortChanged)
        effortPopup.setAccessibilityLabel("Reasoning effort")
        if let index = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            effortPopup.selectItem(at: index)
        }
        let effortRow = SettingsRowView(
            title: "Reasoning effort",
            detail: "Balances speed and depth",
            controlView: effortPopup,
            showsSeparator: false)
        content.addSubview(effortRow)

        card.onLayout = { [weak card, weak effortRow] in
            guard let card, let effortRow else { return }
            effortRow.frame = NSRect(
                x: 0, y: card.bodyFrame.maxY - effortRow.preferredHeight,
                width: card.bodyFrame.width, height: effortRow.preferredHeight)
        }
        card.onLayout?()
        return card
    }

    private func refreshSignIns() {
        guard signInTask == nil else { return }
        let supervisor = supervisor
        signInTask = Task { [weak self] in
            // Only a saved sign-in is worth starting the helper for; with none, no subscription can
            // be chosen and the helper stays unstarted.
            let hasAccount = SubscriptionControls.providers.contains {
                !supervisor.accountFiles(for: $0).isEmpty
            }
            let readiness = hasAccount ? await supervisor.readiness() : nil
            guard !Task.isCancelled, let self else { return }
            signInTask = nil
            if case .ready(_, let signedIn) = readiness {
                signedInSubscriptions = signedIn
            } else {
                signedInSubscriptions = []
            }
            renderRoute()
        }
    }

    private func renderRoute() {
        providerEditor?.render(signedInSubscriptions: signedInSubscriptions, activeTarget: activeTarget)
    }

    private func recalculateDocumentHeight() {
        guard let stack = documentStack else { return }
        let visibleHeights = [
            providerEditor?.preferredHeight,
            Self.coachingCardHeight,
            capabilities.preferredHeight,
            transcription.preferredHeight,
        ].compactMap { $0 }
        let contentHeight = visibleHeights.reduce(0, +)
            + CGFloat(max(0, visibleHeights.count - 1)) * SettingsStyle.sectionSpacing
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

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
        onPreferencesChanged(.effort)
    }
}
