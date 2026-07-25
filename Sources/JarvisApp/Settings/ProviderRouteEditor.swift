import AppKit
import JarvisCore

/// The complete persisted brain-provider route shown as one uninterrupted Settings card.
///
/// Primary and fallback targets share one row language because they are one ordered route. This
/// AppKit adapter owns only editing and availability presentation; runtime failover remains in Core.
@MainActor
final class ProviderRouteEditor: NSObject {
    let view = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: 138))

    private let preferences: BrainPreferences
    private let onChange: () -> Void
    private let onHeightChanged: (CGFloat) -> Void
    private let groupLabel = NSTextField(labelWithString: "PROVIDER")
    private let addButton = NSButton(title: "＋ Add fallback", target: nil, action: nil)
    private var primaryRow: BrainTargetRowView?
    private var fallbackRows: [BrainTargetRowView] = []
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    private var activeTarget: BrainTarget?

    private static let headerHeight: CGFloat = 42
    private static let rowHeight: CGFloat = 54
    private static let addHeight: CGFloat = 42

    var preferredHeight: CGFloat {
        Self.headerHeight
            + CGFloat(preferences.fallbackTargets.count + 1) * Self.rowHeight
            + Self.addHeight
    }

    init(
        preferences: BrainPreferences,
        onChange: @escaping () -> Void,
        onHeightChanged: @escaping (CGFloat) -> Void
    ) {
        self.preferences = preferences
        self.onChange = onChange
        self.onHeightChanged = onHeightChanged
        super.init()
        build()
        view.onLayout = { [weak self] in self?.layoutRows() }
    }

    func render(
        detectedCLIs: [BrainProvider: DetectedAgentCLI]?,
        activeTarget: BrainTarget? = nil
    ) {
        self.detectedCLIs = detectedCLIs
        self.activeTarget = activeTarget

        primaryRow?.removeFromSuperview()
        primaryRow = nil
        fallbackRows.forEach { $0.removeFromSuperview() }
        fallbackRows.removeAll()

        let primaryTarget = preferences.configuredPrimaryTarget
        let primary = BrainTargetRowView(
            title: "Primary",
            status: primaryTarget != nil && primaryTarget == activeTarget ? "In use" : nil,
            target: primaryTarget,
            providerTitle: { [weak self] provider in
                self?.providerTitle(for: provider) ?? provider.displayName
            },
            canSelectProvider: { [weak self] provider in
                self?.availablePrimaryModel(for: provider) != nil
            },
            canSelectModel: { [weak self] model in
                guard let self, let primaryTarget else { return false }
                let candidate = BrainTarget(
                    provider: primaryTarget.provider, modelID: model.id)
                return candidate == primaryTarget
                    || !preferences.fallbackTargets.contains(candidate)
            },
            onProviderChanged: { [weak self] provider in
                self?.primaryProviderChanged(to: provider)
            },
            onModelChanged: { [weak self] model in
                self?.primaryModelChanged(to: model)
            })
        view.contentView?.addSubview(primary)
        primaryRow = primary

        for (index, target) in preferences.fallbackTargets.enumerated() {
            let title = "Fallback \(index + 1)"
            let row = BrainTargetRowView(
                title: title,
                status: target == activeTarget ? "In use" : nil,
                target: target,
                providerTitle: { [weak self] provider in
                    self?.providerTitle(for: provider) ?? provider.displayName
                },
                canSelectProvider: { [weak self] provider in
                    self?.canSelect(provider: provider, replacingTargetAt: index) ?? false
                },
                canSelectModel: { [weak self] model in
                    guard let self else { return false }
                    return !self.isDuplicate(
                        BrainTarget(provider: target.provider, modelID: model.id),
                        replacingTargetAt: index)
                },
                actions: BrainTargetRowView.Actions(
                    canMoveUp: index > 0,
                    canMoveDown: index < preferences.fallbackTargets.count - 1,
                    moveUp: { [weak self] in self?.move(from: index, offset: -1) },
                    moveDown: { [weak self] in self?.move(from: index, offset: 1) },
                    remove: { [weak self] in self?.remove(at: index) }),
                onProviderChanged: { [weak self] provider in
                    self?.changeProvider(at: index, to: provider)
                },
                onModelChanged: { [weak self] model in
                    self?.changeModel(at: index, to: model)
                })
            view.contentView?.addSubview(row)
            fallbackRows.append(row)
        }

        addButton.isEnabled =
            preferences.configuredPrimaryTarget != nil && nextAvailableTarget() != nil
        if let content = view.contentView {
            // Rows are rebuilt on each edit. Keep Add last in accessibility and keyboard order.
            addButton.removeFromSuperview()
            content.addSubview(addButton)
        }
        view.frame.size.height = preferredHeight
        layoutRows()
        onHeightChanged(preferredHeight)
    }

    private func build() {
        view.boxType = .custom
        view.borderWidth = 1
        view.cornerRadius = 12
        view.borderColor = .separatorColor
        view.fillColor = .controlBackgroundColor
        view.contentViewMargins = .zero

        groupLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        groupLabel.textColor = .secondaryLabelColor
        groupLabel.setAccessibilityLabel("Provider")
        view.contentView?.addSubview(groupLabel)

        addButton.target = self
        addButton.action = #selector(addFallback)
        addButton.bezelStyle = .rounded
        addButton.setAccessibilityLabel("Add fallback target")
        view.contentView?.addSubview(addButton)
    }

    private func layoutRows() {
        let width = view.bounds.width
        let height = preferredHeight
        groupLabel.frame = NSRect(
            x: 16, y: height - 30, width: width - 32, height: 18)
        primaryRow?.frame = rowFrame(at: 0, width: width, height: height)
        for (index, row) in fallbackRows.enumerated() {
            row.frame = rowFrame(at: index + 1, width: width, height: height)
        }
        addButton.frame = NSRect(x: 12, y: 5, width: 132, height: 32)
    }

    private func rowFrame(at index: Int, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: 16,
            y: height - Self.headerHeight - CGFloat(index + 1) * Self.rowHeight,
            width: max(200, width - 32),
            height: Self.rowHeight)
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
        let currentProvider = preferences.configuredPrimaryTarget?.provider
        guard isAvailableForNewSelection(provider) || provider == currentProvider else {
            return nil
        }
        let preferred = preferences.model(for: provider)
        if !preferences.fallbackTargets.contains(
            BrainTarget(provider: provider, modelID: preferred.id)) {
            return preferred
        }
        return BrainModelCatalog.models(for: provider).first {
            !preferences.fallbackTargets.contains(
                BrainTarget(provider: provider, modelID: $0.id))
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
        if candidate == preferences.configuredPrimaryTarget { return true }
        return preferences.fallbackTargets.enumerated().contains {
            $0.offset != index && $0.element == candidate
        }
    }

    private func nextAvailableTarget() -> BrainTarget? {
        guard let primary = preferences.configuredPrimaryTarget else { return nil }
        let configuredProviders = Set(
            [primary.provider] + preferences.fallbackTargets.map(\.provider))
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

    private func primaryProviderChanged(to provider: BrainProvider) {
        guard let model = availablePrimaryModel(for: provider) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
            return
        }
        preferences.provider = provider
        preferences.setModel(model, for: provider)
        render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        onChange()
    }

    private func primaryModelChanged(to model: BrainModel) {
        guard let primary = preferences.configuredPrimaryTarget else { return }
        let candidate = BrainTarget(provider: primary.provider, modelID: model.id)
        guard candidate == primary || !preferences.fallbackTargets.contains(candidate) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
            return
        }
        preferences.setModel(model, for: primary.provider)
        render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        onChange()
    }

    @objc private func addFallback() {
        guard let target = nextAvailableTarget() else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            return
        }
        var targets = preferences.fallbackTargets
        targets.append(target)
        save(targets)
    }

    private func changeProvider(at index: Int, to provider: BrainProvider) {
        var targets = preferences.fallbackTargets
        guard targets.indices.contains(index) else { return }
        let preferred = preferences.model(for: provider).id
        guard let model = availableModel(
            for: provider, replacingTargetAt: index, preferredModelID: preferred) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
            return
        }
        targets[index] = BrainTarget(provider: provider, modelID: model.id)
        save(targets)
    }

    private func changeModel(at index: Int, to model: BrainModel) {
        var targets = preferences.fallbackTargets
        guard targets.indices.contains(index) else { return }
        let target = targets[index]
        let candidate = BrainTarget(provider: target.provider, modelID: model.id)
        guard !isDuplicate(candidate, replacingTargetAt: index) else {
            NSSound.beep() // ghost-mode-allowed: explicit user action in Settings
            render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
            return
        }
        targets[index] = candidate
        save(targets)
    }

    private func move(from index: Int, offset: Int) {
        var targets = preferences.fallbackTargets
        let destination = index + offset
        guard targets.indices.contains(index), targets.indices.contains(destination) else { return }
        targets.swapAt(index, destination)
        save(targets)
    }

    private func remove(at index: Int) {
        var targets = preferences.fallbackTargets
        guard targets.indices.contains(index) else { return }
        targets.remove(at: index)
        save(targets)
    }

    private func save(_ targets: [BrainTarget]) {
        preferences.fallbackTargets = targets
        render(detectedCLIs: detectedCLIs, activeTarget: activeTarget)
        onChange()
    }
}
