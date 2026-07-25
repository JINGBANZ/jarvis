import AppKit
import JarvisCore

/// Settings panel for the saved provider route, shared reasoning effort, and OpenAI API key.
///
/// The hierarchy follows the provider-fallback design artifact: a session-only live banner, one
/// inline primary target, the ordered inline fallback card, a separate reasoning card, and the
/// transcription key. The complete tab uses one outer scroll view; fallback rows expand in place.
/// Every completed edit persists immediately through `BrainPreferences`, while the driver applies
/// the new route only between attempts.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    let title = "Brain"
    let fillsTab = true

    private static let liveBannerHeight: CGFloat = 74
    private static let primaryCardHeight: CGFloat = 132
    private static let reasoningCardHeight: CGFloat = 104
    private static let apiKeyCardHeight: CGFloat = 208
    private static let sectionSpacing: CGFloat = 16
    private static let documentInsets: CGFloat = 24

    private let preferences: BrainPreferences
    private let detector: AgentCLIDetector
    private let onPreferencesChanged: ([BrainProvider: DetectedAgentCLI]?) -> Void
    private let apiKey: APIKeyControls

    private var scrollView: NSScrollView?
    private var documentStack: NSStackView?
    private var liveBanner: NSBox?
    private var liveTitle: NSTextField?
    private var liveDetail: NSTextField?
    private var primaryContent: NSView?
    private var primaryRow: BrainTargetRowView?
    private var providerNote: NSTextField?
    private var fallbackEditor: FallbackRouteEditor?
    private var fallbackHeightConstraint: NSLayoutConstraint?
    /// The latest completed probe remains usable while the next refresh runs in the background.
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    /// Deliberately survives a Settings close so a local-provider edit made during the probe still
    /// reaches the running coaching session when detection finishes.
    private var detectionTask: Task<Void, Never>?
    /// Several edits during one probe collapse into one application of the latest persisted values.
    private var applyPreferencesAfterDetection = false
    /// Session-local runtime state only. This marker never writes preferences or reorders the route.
    private var activeTarget: BrainTarget?

    init(
        preferences: BrainPreferences,
        detector: AgentCLIDetector,
        onPreferencesChanged: @escaping ([BrainProvider: DetectedAgentCLI]?) -> Void,
        keyStore: FileSecretStore,
        onKeySaved: @escaping (String) -> Void
    ) {
        self.preferences = preferences
        self.detector = detector
        self.onPreferencesChanged = onPreferencesChanged
        self.apiKey = APIKeyControls(store: keyStore, onKeySaved: onKeySaved)
    }

    func makeView() -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = Self.sectionSpacing
        stack.edgeInsets = NSEdgeInsets(
            top: Self.documentInsets,
            left: Self.documentInsets,
            bottom: Self.documentInsets,
            right: Self.documentInsets)
        stack.autoresizingMask = [.width]
        scrollView.documentView = stack
        self.scrollView = scrollView
        self.documentStack = stack

        let liveBanner = makeLiveBanner()
        liveBanner.heightAnchor.constraint(
            equalToConstant: Self.liveBannerHeight).isActive = true
        stack.addArrangedSubview(liveBanner)
        self.liveBanner = liveBanner

        let primaryCard = makePrimaryCard()
        primaryCard.heightAnchor.constraint(
            equalToConstant: Self.primaryCardHeight).isActive = true
        stack.addArrangedSubview(primaryCard)

        let fallbackEditor = FallbackRouteEditor(
            preferences: preferences,
            onChange: { [weak self] in
                self?.renderPrimary()
                self?.preferencesDidChange()
            },
            onHeightChanged: { [weak self] height in
                self?.fallbackHeightConstraint?.constant = height
                self?.recalculateDocumentHeight()
            })
        fallbackEditor.view.translatesAutoresizingMaskIntoConstraints = false
        let fallbackHeight = fallbackEditor.view.heightAnchor.constraint(
            equalToConstant: fallbackEditor.preferredHeight)
        fallbackHeight.isActive = true
        fallbackHeightConstraint = fallbackHeight
        stack.addArrangedSubview(fallbackEditor.view)
        self.fallbackEditor = fallbackEditor

        let reasoningCard = makeReasoningCard()
        reasoningCard.heightAnchor.constraint(
            equalToConstant: Self.reasoningCardHeight).isActive = true
        stack.addArrangedSubview(reasoningCard)

        let apiKeyCard = makeAPIKeyCard()
        apiKeyCard.heightAnchor.constraint(
            equalToConstant: Self.apiKeyCardHeight).isActive = true
        stack.addArrangedSubview(apiKeyCard)

        renderDetection()
        renderLiveBanner()
        recalculateDocumentHeight()
        revealTop()
        return scrollView
    }

    /// Reflect the driver's selected runtime target without mutating the saved route.
    func setActiveTarget(_ target: BrainTarget?) {
        activeTarget = target
        renderLiveBanner()
        fallbackEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
    }

    /// Re-probe whenever the tab becomes visible so an install or sign-in completed while the app
    /// was open appears. The subprocesses stay off the main actor; cached or base labels render
    /// immediately and the status suffixes update when detection finishes.
    func didBecomeActive() {
        refreshDetection()
    }

    private func makeLiveBanner() -> NSBox {
        let banner = Self.makeCard(
            fillColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
            borderColor: NSColor.controlAccentColor.withAlphaComponent(0.35))

        let title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .labelColor
        title.frame = NSRect(x: 14, y: 40, width: 560, height: 20)
        title.autoresizingMask = [.width]
        banner.contentView?.addSubview(title)
        liveTitle = title

        let detail = NSTextField(labelWithString: "")
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 14, y: 16, width: 560, height: 20)
        detail.autoresizingMask = [.width]
        banner.contentView?.addSubview(detail)
        liveDetail = detail

        let badge = NSTextField(labelWithString: "Live session")
        badge.alignment = .center
        badge.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .controlAccentColor
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        badge.layer?.masksToBounds = true
        badge.frame = NSRect(x: 590, y: 36, width: 92, height: 22)
        badge.autoresizingMask = [.minXMargin]
        banner.contentView?.addSubview(badge)
        return banner
    }

    private func makePrimaryCard() -> NSBox {
        let card = Self.makeCard()
        guard let content = card.contentView else { return card }
        primaryContent = content

        let groupLabel = Self.groupLabel("PRIMARY")
        groupLabel.frame = NSRect(x: 16, y: 102, width: 300, height: 18)
        content.addSubview(groupLabel)

        let note = NSTextField(labelWithString: "")
        note.frame = NSRect(x: 16, y: 14, width: 648, height: 20)
        note.autoresizingMask = [.width]
        note.textColor = .secondaryLabelColor
        content.addSubview(note)
        providerNote = note
        return card
    }

    private func makeReasoningCard() -> NSBox {
        let card = Self.makeCard()
        guard let content = card.contentView else { return card }

        let groupLabel = Self.groupLabel("REASONING")
        groupLabel.frame = NSRect(x: 16, y: 73, width: 300, height: 18)
        content.addSubview(groupLabel)

        let effortLabel = NSTextField(labelWithString: "Effort")
        effortLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        effortLabel.frame = NSRect(x: 16, y: 27, width: 92, height: 20)
        content.addSubview(effortLabel)

        let effortPopup = NSPopUpButton(frame: NSRect(x: 117, y: 21, width: 220, height: 32))
        effortPopup.addItems(withTitles: ReasoningEffort.allCases.map(\.displayName))
        effortPopup.target = self
        effortPopup.action = #selector(effortChanged)
        effortPopup.setAccessibilityLabel("Reasoning effort")
        if let row = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            effortPopup.selectItem(at: row)
        }
        content.addSubview(effortPopup)

        let sharedNote = NSTextField(wrappingLabelWithString:
            "Shared by every route target")
        sharedNote.frame = NSRect(x: 356, y: 20, width: 308, height: 36)
        sharedNote.autoresizingMask = [.width]
        sharedNote.textColor = .secondaryLabelColor
        content.addSubview(sharedNote)
        return card
    }

    private func makeAPIKeyCard() -> NSBox {
        let card = Self.makeCard()
        guard let content = card.contentView else { return card }

        let groupLabel = Self.groupLabel("OPENAI API KEY")
        groupLabel.frame = NSRect(x: 16, y: 177, width: 300, height: 18)
        content.addSubview(groupLabel)

        let note = NSTextField(labelWithString:
            "Needed for voice transcription even when the brain runs on a local CLI.")
        note.frame = NSRect(x: 16, y: 153, width: 648, height: 20)
        note.autoresizingMask = [.width]
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        apiKey.addControls(to: content, top: 119, x: 16, width: 648)
        return card
    }

    private static func makeCard(
        fillColor: NSColor = .controlBackgroundColor,
        borderColor: NSColor = .separatorColor
    ) -> NSBox {
        let card = NSBox(frame: NSRect(x: 0, y: 0, width: 712, height: 100))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.boxType = .custom
        card.borderWidth = 1
        card.cornerRadius = 12
        card.borderColor = borderColor
        card.fillColor = fillColor
        card.contentViewMargins = .zero
        return card
    }

    private static func groupLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func refreshDetection() {
        guard detectionTask == nil else { return }
        let detector = detector
        detectionTask = Task { [weak self] in
            let values = await detector.detectAllAsync()
            guard !Task.isCancelled, let self else { return }
            detectionTask = nil
            detectedCLIs = Dictionary(uniqueKeysWithValues: values.map { ($0.provider, $0) })
            renderDetection()
            if applyPreferencesAfterDetection {
                applyPreferencesAfterDetection = false
                onPreferencesChanged(detectedCLIs)
            }
        }
    }

    private func renderDetection() {
        renderPrimary()
        fallbackEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        renderLiveBanner()
    }

    private func renderPrimary() {
        guard let content = primaryContent else { return }
        primaryRow?.removeFromSuperview()

        let target = preferences.primaryTarget
        let row = BrainTargetRowView(
            title: "Primary",
            target: target,
            providerTitle: { [weak self] provider in
                self?.providerTitle(for: provider) ?? provider.displayName
            },
            canSelectProvider: { [weak self] provider in
                self?.availablePrimaryModel(for: provider) != nil
            },
            canSelectModel: { [weak self] model in
                guard let self else { return false }
                let candidate = BrainTarget(provider: target.provider, modelID: model.id)
                return candidate == target || !preferences.fallbackTargets.contains(candidate)
            },
            trailingBadge: "SAVED START",
            onProviderChanged: { [weak self] provider in
                self?.primaryProviderChanged(to: provider)
            },
            onModelChanged: { [weak self] model in
                self?.primaryModelChanged(to: model)
            })
        row.frame = NSRect(x: 16, y: 40, width: max(200, content.bounds.width - 32), height: 52)
        row.autoresizingMask = [.width]
        content.addSubview(row)
        primaryRow = row

        providerNote?.stringValue = Self.note(for: target.provider)
    }

    private func renderLiveBanner() {
        guard let liveBanner else { return }
        guard let activeTarget else {
            liveBanner.isHidden = true
            recalculateDocumentHeight()
            return
        }

        let position: String
        if activeTarget == preferences.primaryTarget {
            position = "Primary"
        } else if let index = preferences.fallbackTargets.firstIndex(of: activeTarget) {
            position = "Fallback \(index + 1)"
        } else {
            position = "Current route"
        }
        let model = activeTarget.model?.displayName ?? activeTarget.modelID
        liveTitle?.stringValue =
            "Currently using \(position) · \(activeTarget.provider.displayName) · \(model)"
        liveDetail?.stringValue =
            "The saved route has not changed. Runtime failover never rewrites or reorders these preferences."
        liveBanner.isHidden = false
        recalculateDocumentHeight()
    }

    private func providerTitle(for provider: BrainProvider) -> String {
        guard provider.usesLocalCLI, let detectedCLIs else { return provider.displayName }
        guard let cli = detectedCLIs[provider] else {
            return "\(provider.displayName) — not installed"
        }
        switch cli.authenticationStatus {
        case .signedIn: return "\(provider.displayName) — signed in"
        case .signedOut: return "\(provider.displayName) — signed out"
        case .unknown: return "\(provider.displayName) — sign-in unknown"
        }
    }

    private func availablePrimaryModel(for provider: BrainProvider) -> BrainModel? {
        guard isAvailableForNewSelection(provider) || provider == preferences.provider else {
            return nil
        }
        let models = BrainModelCatalog.models(for: provider)
        let preferred = preferences.model(for: provider)
        if !preferences.fallbackTargets.contains(
            BrainTarget(provider: provider, modelID: preferred.id)) {
            return preferred
        }
        return models.first {
            !preferences.fallbackTargets.contains(
                BrainTarget(provider: provider, modelID: $0.id))
        }
    }

    private func isAvailableForNewSelection(_ provider: BrainProvider) -> Bool {
        guard provider.usesLocalCLI, let detectedCLIs else { return true }
        guard let cli = detectedCLIs[provider] else { return false }
        return cli.authenticationStatus != .signedOut
    }

    private static func note(for provider: BrainProvider) -> String {
        switch provider {
        case .openAI:
            return "Coaching runs on the OpenAI API, billed to the key below."
        case .claudeCode:
            return "Coaching runs through your local Claude Code CLI — billed to your Claude subscription."
        case .codexCLI:
            return "Coaching runs through your local Codex CLI — billed to your ChatGPT subscription."
        }
    }

    private func recalculateDocumentHeight() {
        guard let stack = documentStack else { return }
        let visibleHeights = [
            activeTarget == nil ? nil : Self.liveBannerHeight,
            Self.primaryCardHeight,
            fallbackEditor?.preferredHeight,
            Self.reasoningCardHeight,
            Self.apiKeyCardHeight,
        ].compactMap { $0 }
        let height = Self.documentInsets * 2
            + visibleHeights.reduce(0, +)
            + CGFloat(max(0, visibleHeights.count - 1)) * Self.sectionSpacing
        let viewportHeight = scrollView?.contentView.bounds.height ?? 0
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

    private func primaryProviderChanged(to provider: BrainProvider) {
        guard let model = availablePrimaryModel(for: provider) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            renderPrimary()
            return
        }
        preferences.setModel(model, for: provider)
        preferences.provider = provider
        renderDetection()
        preferencesDidChange()
    }

    private func primaryModelChanged(to model: BrainModel) {
        let candidate = BrainTarget(provider: preferences.provider, modelID: model.id)
        guard candidate == preferences.primaryTarget
                || !preferences.fallbackTargets.contains(candidate) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            renderPrimary()
            return
        }
        preferences.setModel(model, for: preferences.provider)
        renderDetection()
        preferencesDidChange()
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
        preferencesDidChange()
    }

    private func preferencesDidChange() {
        let providers = [preferences.provider] + preferences.fallbackTargets.map(\.provider)
        guard providers.contains(where: \.usesLocalCLI) else {
            applyPreferencesAfterDetection = false
            onPreferencesChanged([:])
            return
        }
        // Never apply a cached preflight while a fresher probe is running. The completion collapses
        // any edits made during that probe into one application of the latest persisted preferences.
        if detectionTask != nil {
            applyPreferencesAfterDetection = true
            return
        }
        if let detectedCLIs {
            onPreferencesChanged(detectedCLIs)
        } else {
            applyPreferencesAfterDetection = true
            refreshDetection()
        }
    }
}
