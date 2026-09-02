import AppKit
import JarvisCore
import JarvisBrainProviders

/// Minimal Brain Settings surface: one provider route, one reasoning-effort row, and transcription.
///
/// Provider/model ordering is edited by `ProviderRouteEditor`; shared authentication lives in the
/// Connections tab. This section composes behavior controls, refreshes CLI availability, and applies
/// completed preference edits at the running driver's between-attempt boundary.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    enum PreferenceChange: Equatable {
        case topology
        case effort

        func merged(with newer: PreferenceChange) -> PreferenceChange {
            self == .topology || newer == .topology ? .topology : .effort
        }
    }

    let title = "Brain"
    let fillsTab = true

    private static let coachingCardHeight =
        SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight * 2

    private let preferences: BrainPreferences
    private let detector: AgentCLIDetector
    private let onPreferencesChanged:
        (PreferenceChange, [BrainProvider: DetectedAgentCLI]?) -> Void
    private let transcription: TranscriptionControls

    private var pageView: SettingsPageView?
    private var scrollView: SettingsScrollView?
    private var documentStack: NSStackView?
    private var providerEditor: ProviderRouteEditor?
    private var providerHeightConstraint: NSLayoutConstraint?
    private var transcriptionHeightConstraint: NSLayoutConstraint?
    /// The latest completed probe remains usable while the next refresh runs in the background.
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    /// Deliberately survives a Settings close so an edit made during the probe still reaches the
    /// running coaching session when detection finishes.
    private var detectionTask: Task<Void, Never>?
    private var pendingPreferenceChange: PreferenceChange?
    /// Session-local runtime state only. This marker never writes preferences or reorders the route.
    private var activeTarget: BrainTarget?

    init(
        preferences: BrainPreferences,
        detector: AgentCLIDetector,
        onPreferencesChanged:
            @escaping (PreferenceChange, [BrainProvider: DetectedAgentCLI]?) -> Void,
        transcriptionPreferences: TranscriptionPreferences
    ) {
        self.preferences = preferences
        self.detector = detector
        self.onPreferencesChanged = onPreferencesChanged
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
            onChange: { [weak self] in self?.preferencesDidChange(.topology) },
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
        renderDetection()
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
        providerEditor?.render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
    }

    func didBecomeActive() {
        refreshDetection()
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
            controlView: effortPopup)
        content.addSubview(effortRow)

        // "Automatic" (index 0) persists as `nil` — not selected, resolved to every format's
        // combined guidance rather than a guess. See `InterviewFormat.resolvedPromptAddendum(for:)`.
        let formatPopup = NSPopUpButton()
        formatPopup.addItem(withTitle: "Automatic")
        formatPopup.addItems(withTitles: InterviewFormat.allCases.map(\.displayName))
        formatPopup.target = self
        formatPopup.action = #selector(interviewFormatChanged)
        formatPopup.setAccessibilityLabel("Interview format")
        if let format = preferences.interviewFormat,
           let index = InterviewFormat.allCases.firstIndex(of: format) {
            formatPopup.selectItem(at: index + 1)
        } else {
            formatPopup.selectItem(at: 0)
        }
        let formatRow = SettingsRowView(
            title: "Interview format",
            detail: "Applies on the next Start",
            controlView: formatPopup,
            showsSeparator: false)
        content.addSubview(formatRow)

        card.onLayout = { [weak card, weak effortRow, weak formatRow] in
            guard let card, let effortRow, let formatRow else { return }
            var top = card.bodyFrame.maxY
            top -= effortRow.preferredHeight
            effortRow.frame = NSRect(
                x: 0, y: top, width: card.bodyFrame.width, height: effortRow.preferredHeight)
            top -= formatRow.preferredHeight
            formatRow.frame = NSRect(
                x: 0, y: top, width: card.bodyFrame.width, height: formatRow.preferredHeight)
        }
        card.onLayout?()
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
            if let change = pendingPreferenceChange {
                pendingPreferenceChange = nil
                onPreferencesChanged(change, detectedCLIs)
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
            Self.coachingCardHeight,
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
        preferencesDidChange(.effort)
    }

    /// Fixed for the whole session like the transcription language/model choice — applies on the
    /// next Start only, so this never triggers the CLI-preflight reapply `preferencesDidChange` owns.
    @objc private func interviewFormatChanged(_ sender: NSPopUpButton) {
        let row = sender.indexOfSelectedItem
        guard row == 0 || InterviewFormat.allCases.indices.contains(row - 1) else { return }
        let format = row == 0 ? nil : InterviewFormat.allCases[row - 1]
        preferences.interviewFormat = format
        jlog("Jarvis: \(format?.displayName ?? "Automatic") interview format selected for the "
            + "next Start.")
    }

    private func preferencesDidChange(_ change: PreferenceChange) {
        let providers = preferences.route.targets.map(\.provider)
        guard providers.contains(where: \.usesLocalCLI) else {
            pendingPreferenceChange = nil
            onPreferencesChanged(change, [:])
            return
        }
        // Never apply a cached preflight while a fresher probe is running. The completion collapses
        // any edits made during that probe into one application of the latest persisted preferences.
        if detectionTask != nil {
            pendingPreferenceChange = pendingPreferenceChange?.merged(with: change) ?? change
            return
        }
        if let detectedCLIs {
            onPreferencesChanged(change, detectedCLIs)
        } else {
            pendingPreferenceChange = pendingPreferenceChange?.merged(with: change) ?? change
            refreshDetection()
        }
    }
}
