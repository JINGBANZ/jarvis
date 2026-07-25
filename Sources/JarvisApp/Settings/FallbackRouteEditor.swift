import AppKit
import JarvisCore

/// Ordered fallback-target list editing for the Brain Settings section.
///
/// This AppKit adapter owns only list rendering and discrete preference mutations. It deliberately
/// knows nothing about attempt scheduling or runtime failover; `onChange` lets `BrainSection`
/// preflight and apply the newly persisted route through the existing session boundary.
@MainActor
final class FallbackRouteEditor: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 512, height: 214))

    private let preferences: BrainPreferences
    private let onChange: () -> Void
    private let rowsView = NSView(frame: NSRect(x: 0, y: 0, width: 492, height: 142))
    private let addButton: NSButton
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    private var activeTarget: BrainTarget?

    init(preferences: BrainPreferences, onChange: @escaping () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
        self.addButton = NSButton(title: "Add fallback", target: nil, action: nil)
        super.init()
        build()
    }

    func render(
        detectedCLIs: [BrainProvider: DetectedAgentCLI]?,
        activeTarget: BrainTarget? = nil
    ) {
        self.detectedCLIs = detectedCLIs
        self.activeTarget = activeTarget
        let rowsScroll = rowsView.enclosingScrollView
        let oldDocumentHeight = rowsView.frame.height
        let viewportHeight = rowsScroll?.contentView.bounds.height ?? oldDocumentHeight
        let distanceFromTop = max(
            0,
            oldDocumentHeight
                - (rowsScroll?.contentView.bounds.origin.y ?? 0)
                - viewportHeight)
        rowsView.subviews.forEach { $0.removeFromSuperview() }

        let targets = preferences.fallbackTargets
        let rowHeight: CGFloat = 38
        let documentHeight = max(142, CGFloat(targets.count) * rowHeight + 8)
        rowsView.frame.size.height = documentHeight

        guard !targets.isEmpty else {
            let empty = NSTextField(labelWithString: "No fallback targets")
            empty.frame = NSRect(x: 12, y: 60, width: 460, height: 20)
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            rowsView.addSubview(empty)
            addButton.isEnabled = nextAvailableTarget() != nil
            restoreScrollPosition(
                rowsScroll, documentHeight: documentHeight,
                viewportHeight: viewportHeight, distanceFromTop: distanceFromTop)
            return
        }

        for (index, target) in targets.enumerated() {
            addRow(for: target, at: index, targetCount: targets.count,
                   y: documentHeight - 38 - CGFloat(index) * rowHeight)
        }
        addButton.isEnabled = nextAvailableTarget() != nil
        restoreScrollPosition(
            rowsScroll, documentHeight: documentHeight,
            viewportHeight: viewportHeight, distanceFromTop: distanceFromTop)
    }

    private func build() {
        for (title, x, width) in [
            ("Priority", CGFloat(8), CGFloat(68)),
            ("Provider", CGFloat(80), CGFloat(130)),
            ("Model", CGFloat(214), CGFloat(136)),
            ("Actions", CGFloat(354), CGFloat(120)),
        ] {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: x, y: 198, width: width, height: 18)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            view.addSubview(label)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 46, width: 512, height: 144))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = rowsView
        view.addSubview(scrollView)

        addButton.target = self
        addButton.action = #selector(addFallback)
        addButton.frame = NSRect(x: -4, y: 4, width: 122, height: 32)
        addButton.bezelStyle = .rounded
        addButton.setAccessibilityLabel("Add fallback target")
        view.addSubview(addButton)

        let routeNote = NSTextField(wrappingLabelWithString:
            "3 temporary/unknown failed attempts, or 1 proven permanent failure, advance on the next fresh attempt. The saved order never changes automatically.")
        routeNote.frame = NSRect(x: 126, y: 0, width: 386, height: 38)
        routeNote.textColor = .secondaryLabelColor
        view.addSubview(routeNote)
    }

    private func addRow(
        for target: BrainTarget,
        at index: Int,
        targetCount: Int,
        y: CGFloat
    ) {
        let label = NSTextField(labelWithString: "Fallback \(index + 1)")
        label.frame = NSRect(x: 8, y: y + 7, width: 68, height: 20)
        let isActive = target == activeTarget
        if isActive {
            label.textColor = .controlAccentColor
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let marker = NSTextField(labelWithString: "●")
            marker.frame = NSRect(x: 67, y: y + 7, width: 10, height: 20)
            marker.textColor = .controlAccentColor
            marker.setAccessibilityElement(false)
            rowsView.addSubview(marker)
        }
        label.setAccessibilityLabel(
            "Fallback priority \(index + 1)" + (isActive ? ", active this session" : ""))
        rowsView.addSubview(label)

        let providerPopup = NSPopUpButton(frame: NSRect(x: 80, y: y + 3, width: 130, height: 28))
        providerPopup.addItems(withTitles:
            BrainProvider.allCases.map { providerTitle(for: $0) })
        providerPopup.selectItem(at: BrainProvider.allCases.firstIndex(of: target.provider) ?? 0)
        providerPopup.tag = index
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.setAccessibilityLabel("Fallback \(index + 1) provider")
        for (providerIndex, provider) in BrainProvider.allCases.enumerated() {
            providerPopup.item(at: providerIndex)?.isEnabled =
                provider == target.provider || canSelect(
                    provider: provider, replacingTargetAt: index)
        }
        rowsView.addSubview(providerPopup)

        let models = BrainModelCatalog.models(for: target.provider)
        let modelPopup = NSPopUpButton(frame: NSRect(x: 214, y: y + 3, width: 136, height: 28))
        modelPopup.addItems(withTitles: models.map(\.displayName))
        if let selected = models.firstIndex(where: { $0.id == target.modelID }) {
            modelPopup.selectItem(at: selected)
        }
        modelPopup.tag = index
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.setAccessibilityLabel("Fallback \(index + 1) model")
        for (modelIndex, model) in models.enumerated() {
            let candidate = BrainTarget(provider: target.provider, modelID: model.id)
            modelPopup.item(at: modelIndex)?.isEnabled =
                candidate == target || !isDuplicate(candidate, replacingTargetAt: index)
        }
        rowsView.addSubview(modelPopup)

        let moveUp = NSButton(title: "↑", target: self, action: #selector(moveUp))
        moveUp.frame = NSRect(x: 352, y: y + 1, width: 30, height: 30)
        moveUp.bezelStyle = .rounded
        moveUp.tag = index
        moveUp.isEnabled = index > 0
        moveUp.setAccessibilityLabel("Move Fallback \(index + 1) up")
        rowsView.addSubview(moveUp)

        let moveDown = NSButton(title: "↓", target: self, action: #selector(moveDown))
        moveDown.frame = NSRect(x: 384, y: y + 1, width: 30, height: 30)
        moveDown.bezelStyle = .rounded
        moveDown.tag = index
        moveDown.isEnabled = index < targetCount - 1
        moveDown.setAccessibilityLabel("Move Fallback \(index + 1) down")
        rowsView.addSubview(moveDown)

        let remove = NSButton(title: "Remove", target: self, action: #selector(remove))
        remove.frame = NSRect(x: 416, y: y + 1, width: 70, height: 30)
        remove.bezelStyle = .rounded
        remove.tag = index
        remove.setAccessibilityLabel("Remove Fallback \(index + 1)")
        rowsView.addSubview(remove)
    }

    private func restoreScrollPosition(
        _ scrollView: NSScrollView?,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        distanceFromTop: CGFloat
    ) {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(0, documentHeight - viewportHeight - distanceFromTop)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

    private func canSelect(provider: BrainProvider, replacingTargetAt index: Int) -> Bool {
        guard isAvailableForNewSelection(provider) else { return false }
        return availableModel(
            for: provider, replacingTargetAt: index, preferredModelID: nil) != nil
    }

    private func isAvailableForNewSelection(_ provider: BrainProvider) -> Bool {
        guard provider.usesLocalCLI, let detectedCLIs else { return true }
        guard let cli = detectedCLIs[provider] else { return false }
        return cli.authenticationStatus != .signedOut
    }

    private func availableModel(
        for provider: BrainProvider,
        replacingTargetAt index: Int?,
        preferredModelID: String?
    ) -> BrainModel? {
        let models = BrainModelCatalog.models(for: provider)
        if let preferredModelID,
           let preferred = models.first(where: { $0.id == preferredModelID }),
           !isDuplicate(
               BrainTarget(provider: provider, modelID: preferred.id),
               replacingTargetAt: index) {
            return preferred
        }
        return models.first {
            !isDuplicate(
                BrainTarget(provider: provider, modelID: $0.id),
                replacingTargetAt: index)
        }
    }

    private func isDuplicate(_ candidate: BrainTarget, replacingTargetAt index: Int?) -> Bool {
        if candidate == preferences.primaryTarget { return true }
        return preferences.fallbackTargets.enumerated().contains {
            $0.offset != index && $0.element == candidate
        }
    }

    private func nextAvailableTarget() -> BrainTarget? {
        let configuredProviders = Set(
            [preferences.provider] + preferences.fallbackTargets.map(\.provider))
        // Adding a row should normally broaden the route first. Once every available provider is
        // represented, continue offering distinct models from already represented providers.
        let providers = BrainProvider.allCases.filter { !configuredProviders.contains($0) }
            + BrainProvider.allCases.filter { configuredProviders.contains($0) }
        for provider in providers {
            guard isAvailableForNewSelection(provider) else { continue }
            let preferred = preferences.model(for: provider).id
            if let model = availableModel(
                for: provider, replacingTargetAt: nil, preferredModelID: preferred) {
                return BrainTarget(provider: provider, modelID: model.id)
            }
        }
        return nil
    }

    @objc private func addFallback(_ sender: NSButton) {
        guard let target = nextAvailableTarget() else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            return
        }
        var targets = preferences.fallbackTargets
        targets.append(target)
        save(targets)
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let row = sender.tag
        let providerRow = sender.indexOfSelectedItem
        var targets = preferences.fallbackTargets
        guard targets.indices.contains(row),
              BrainProvider.allCases.indices.contains(providerRow) else { return }
        let provider = BrainProvider.allCases[providerRow]
        let preferred = preferences.model(for: provider).id
        guard let model = availableModel(
            for: provider, replacingTargetAt: row, preferredModelID: preferred) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
            return
        }
        targets[row] = BrainTarget(provider: provider, modelID: model.id)
        save(targets)
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let row = sender.tag
        let modelRow = sender.indexOfSelectedItem
        var targets = preferences.fallbackTargets
        guard targets.indices.contains(row) else { return }
        let target = targets[row]
        let models = BrainModelCatalog.models(for: target.provider)
        guard models.indices.contains(modelRow) else { return }
        let candidate = BrainTarget(provider: target.provider, modelID: models[modelRow].id)
        guard !isDuplicate(candidate, replacingTargetAt: row) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
            return
        }
        targets[row] = candidate
        save(targets)
    }

    @objc private func moveUp(_ sender: NSButton) {
        move(from: sender.tag, offset: -1)
    }

    @objc private func moveDown(_ sender: NSButton) {
        move(from: sender.tag, offset: 1)
    }

    private func move(from row: Int, offset: Int) {
        var targets = preferences.fallbackTargets
        let destination = row + offset
        guard targets.indices.contains(row), targets.indices.contains(destination) else { return }
        targets.swapAt(row, destination)
        save(targets)
    }

    @objc private func remove(_ sender: NSButton) {
        var targets = preferences.fallbackTargets
        guard targets.indices.contains(sender.tag) else { return }
        targets.remove(at: sender.tag)
        save(targets)
    }

    private func save(_ targets: [BrainTarget]) {
        preferences.fallbackTargets = targets
        render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        onChange()
    }
}
