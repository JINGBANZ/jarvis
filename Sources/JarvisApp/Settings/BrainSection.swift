import AppKit
import JarvisCore

/// Minimal Brain Settings surface: one provider route, one reasoning-effort row, and transcription.
///
/// Provider/model ordering is edited by `ProviderRouteEditor`; credentials remain isolated in
/// `APIKeyControls`. This section only composes those modules, refreshes CLI availability, and
/// applies completed preference edits at the running driver's between-attempt boundary.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    let title = "Brain"
    let fillsTab = true

    private static let reasoningHeight: CGFloat = 54
    private static let sectionSpacing: CGFloat = 14
    private static let documentInsets: CGFloat = 24

    private let preferences: BrainPreferences
    private let detector: AgentCLIDetector
    private let onPreferencesChanged: ([BrainProvider: DetectedAgentCLI]?) -> Void
    private let apiKey: APIKeyControls

    private var scrollView: NSScrollView?
    private var documentStack: NSStackView?
    private var providerEditor: ProviderRouteEditor?
    private var providerHeightConstraint: NSLayoutConstraint?
    private var transcriptionHeightConstraint: NSLayoutConstraint?
    /// The latest completed probe remains usable while the next refresh runs in the background.
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    /// Deliberately survives a Settings close so an edit made during the probe still reaches the
    /// running coaching session when detection finishes.
    private var detectionTask: Task<Void, Never>?
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

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
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

        let providerEditor = ProviderRouteEditor(
            preferences: preferences,
            onChange: { [weak self] in self?.preferencesDidChange() },
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
            equalToConstant: Self.reasoningHeight).isActive = true
        stack.addArrangedSubview(reasoningCard)

        let transcriptionCard = apiKey.makeView { [weak self] height in
            self?.transcriptionHeightConstraint?.constant = height
            self?.recalculateDocumentHeight()
        }
        transcriptionCard.translatesAutoresizingMaskIntoConstraints = false
        let transcriptionHeight = transcriptionCard.heightAnchor.constraint(
            equalToConstant: apiKey.preferredHeight)
        transcriptionHeight.isActive = true
        transcriptionHeightConstraint = transcriptionHeight
        stack.addArrangedSubview(transcriptionCard)

        renderDetection()
        recalculateDocumentHeight()
        revealTop()
        return scrollView
    }

    /// Reflect the driver's selected runtime target without mutating the saved route.
    func setActiveTarget(_ target: BrainTarget?) {
        activeTarget = target
        providerEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
    }

    func didBecomeActive() {
        refreshDetection()
    }

    private func makeReasoningCard() -> SettingsCardView {
        let card = Self.makeCard()
        guard let content = card.contentView else { return card }

        let label = NSTextField(labelWithString: "Reasoning effort")
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addSubview(label)

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ReasoningEffort.allCases.map(\.displayName))
        popup.target = self
        popup.action = #selector(effortChanged)
        popup.setAccessibilityLabel("Reasoning effort")
        if let row = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            popup.selectItem(at: row)
        }
        content.addSubview(popup)

        card.onLayout = { [weak content, weak label, weak popup] in
            guard let content, let label, let popup else { return }
            let controlWidth = min(220, max(150, content.bounds.width * 0.46))
            label.frame = NSRect(x: 16, y: 17, width: 180, height: 20)
            popup.frame = NSRect(
                x: content.bounds.width - 14 - controlWidth,
                y: 11,
                width: controlWidth,
                height: 32)
        }
        card.onLayout?()
        return card
    }

    private static func makeCard() -> SettingsCardView {
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: 54))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.boxType = .custom
        card.borderWidth = 1
        card.cornerRadius = 12
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = .zero
        return card
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
        providerEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
    }

    private func recalculateDocumentHeight() {
        guard let stack = documentStack else { return }
        let visibleHeights = [
            providerEditor?.preferredHeight,
            Self.reasoningHeight,
            apiKey.preferredHeight,
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

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard ReasoningEffort.allCases.indices.contains(row) else { return }
        preferences.effort = ReasoningEffort.allCases[row]
        preferencesDidChange()
    }

    private func preferencesDidChange() {
        guard let route = preferences.configuredRoute else { return }
        let providers = route.targets.map(\.provider)
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
