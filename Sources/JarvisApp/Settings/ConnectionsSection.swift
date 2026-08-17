import AppKit
import JarvisCore

/// Shared authentication and provider readiness, kept separate from Brain behavior settings.
@MainActor
final class ConnectionsSection: NSObject, SettingsSection {
    let title = "Connections"
    let fillsTab = true

    private static let cliCardHeight = SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight

    private let detector: AgentCLIDetector
    private let apiKeyControls: APIKeyControls
    private var pageView: SettingsPageView?
    private var scrollView: SettingsScrollView?
    private var documentStack: NSStackView?
    private var apiKeyHeightConstraint: NSLayoutConstraint?
    private var statusLabels: [BrainProvider: NSTextField] = [:]
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    private var detectionTask: Task<Void, Never>?

    init(
        detector: AgentCLIDetector,
        keyStore: FileSecretStore,
        onKeySaved: @escaping (String) -> Void
    ) {
        self.detector = detector
        self.apiKeyControls = APIKeyControls(store: keyStore, onKeySaved: onKeySaved)
    }

    func makeView() -> NSView {
        statusLabels.removeAll()
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

        let apiKeyCard = apiKeyControls.makeView { [weak self] height in
            self?.apiKeyHeightConstraint?.constant = height
            self?.recalculateDocumentHeight()
            self?.renderPageStatus()
        }
        apiKeyCard.translatesAutoresizingMaskIntoConstraints = false
        let apiKeyHeight = apiKeyCard.heightAnchor.constraint(
            equalToConstant: apiKeyControls.preferredHeight)
        apiKeyHeight.isActive = true
        apiKeyHeightConstraint = apiKeyHeight
        stack.addArrangedSubview(apiKeyCard)

        for provider in [BrainProvider.claudeCode, .codexCLI] {
            let card = makeCLICard(for: provider)
            card.heightAnchor.constraint(equalToConstant: Self.cliCardHeight).isActive = true
            stack.addArrangedSubview(card)
        }

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
        renderStatuses()
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
        refreshDetection()
    }

    func windowWillClose() {
        detectionTask?.cancel()
        detectionTask = nil
    }

    private func makeCLICard(for provider: BrainProvider) -> SettingsCardView {
        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: Self.cliCardHeight))
        card.setHeader(title: provider.displayName, detail: "Local CLI")
        guard let content = card.contentView else { return card }

        let status = NSTextField(labelWithString: "Checking…")
        status.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        status.alignment = .right
        status.textColor = .secondaryLabelColor
        statusLabels[provider] = status
        let row = SettingsRowView(
            title: "Local account",
            detail: "Authentication stays managed by \(provider.displayName)",
            controlView: status,
            controlSize: NSSize(width: 150, height: 20),
            showsSeparator: false)
        content.addSubview(row)
        card.onLayout = { [weak card, weak row] in
            guard let card, let row else { return }
            row.frame = card.bodyFrame
        }
        card.onLayout?()
        return card
    }

    private func refreshDetection() {
        guard detectionTask == nil else { return }
        let detector = detector
        detectionTask = Task { [weak self] in
            let values = await detector.detectAllAsync([.claudeCode, .codexCLI])
            guard !Task.isCancelled, let self else { return }
            detectionTask = nil
            detectedCLIs = Dictionary(uniqueKeysWithValues: values.map { ($0.provider, $0) })
            renderStatuses()
        }
    }

    private func renderStatuses() {
        for provider in [BrainProvider.claudeCode, .codexCLI] {
            guard let label = statusLabels[provider] else { continue }
            guard let detectedCLIs else {
                set(label, text: "Checking…", color: .secondaryLabelColor)
                continue
            }
            guard let cli = detectedCLIs[provider] else {
                set(label, text: "Not installed", color: .secondaryLabelColor)
                continue
            }
            switch cli.authenticationStatus {
            case .signedIn:
                set(label, text: "Signed in", color: .systemGreen)
            case .signedOut:
                set(label, text: "Signed out", color: .systemOrange)
            case .unknown:
                set(label, text: "Sign-in unknown", color: .secondaryLabelColor)
            }
        }
        renderPageStatus()
    }

    private func set(_ label: NSTextField, text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        label.setAccessibilityLabel(text)
    }

    private func renderPageStatus() {
        guard detectedCLIs != nil else {
            pageView?.setStatus(nil)
            return
        }
        let signedInCount = detectedCLIs?.values.filter {
            $0.authenticationStatus == .signedIn
        }.count ?? 0
        let readyCount = signedInCount + (apiKeyControls.hasSavedKey ? 1 : 0)
        pageView?.setStatus("\(readyCount) ready")
    }

    private func recalculateDocumentHeight() {
        guard let stack = documentStack else { return }
        let visibleHeights = [
            apiKeyControls.preferredHeight,
            Self.cliCardHeight,
            Self.cliCardHeight,
        ]
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
