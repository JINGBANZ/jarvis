import AppKit
import JarvisCore

/// Ordered fallback-target list editing for the Brain Settings section.
///
/// This AppKit adapter owns the complete fallback card from the agreed UI: inline rows, ordering
/// controls, the add action, route semantics, and save/apply status. It deliberately knows nothing
/// about attempt scheduling or runtime failover; `onChange` lets `BrainSection` preflight and apply
/// the newly persisted route through the existing session boundary.
@MainActor
final class FallbackRouteEditor: NSObject {
    let view = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: 220))

    private let preferences: BrainPreferences
    private let onChange: () -> Void
    private let onHeightChanged: (CGFloat) -> Void
    private let addButton: NSButton
    private let groupLabel = NSTextField(labelWithString: "FALLBACK ROUTE")
    private let routeNote = NSTextField(wrappingLabelWithString:
        "ⓘ  Jarvis moves forward after 3 temporary/unknown failed attempts, or 1 proven permanent failure. The next row begins only in a fresh attempt. Jarvis stays there after recovery and never changes this saved order automatically.")
    private let savedFooter = NSTextField(labelWithString:
        "Each completed edit is saved immediately.")
    private let applyFooter = NSTextField(labelWithString:
        "Applies on the next coaching attempt")
    private var rowViews: [BrainTargetRowView] = []
    private var emptyLabel: NSTextField?
    private var detectedCLIs: [BrainProvider: DetectedAgentCLI]?
    private var activeTarget: BrainTarget?

    private static let rowHeight: CGFloat = 52
    private static let emptyHeight: CGFloat = 38

    var preferredHeight: CGFloat {
        let rowsHeight = preferences.fallbackTargets.isEmpty
            ? Self.emptyHeight
            : CGFloat(preferences.fallbackTargets.count) * Self.rowHeight
        return 182 + rowsHeight
    }

    init(
        preferences: BrainPreferences,
        onChange: @escaping () -> Void,
        onHeightChanged: @escaping (CGFloat) -> Void
    ) {
        self.preferences = preferences
        self.onChange = onChange
        self.onHeightChanged = onHeightChanged
        self.addButton = NSButton(title: "＋ Add fallback", target: nil, action: nil)
        super.init()
        build()
        view.onLayout = { [weak self] in self?.layoutFixedContent() }
    }

    func render(
        detectedCLIs: [BrainProvider: DetectedAgentCLI]?,
        activeTarget: BrainTarget? = nil
    ) {
        self.detectedCLIs = detectedCLIs
        self.activeTarget = activeTarget

        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil

        let targets = preferences.fallbackTargets
        let height = preferredHeight
        view.frame.size.height = height

        if targets.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "No fallback targets. Coaching stops after 3 temporary failures or 1 proven permanent primary failure.")
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(
                x: 16, y: height - 92,
                width: max(200, view.bounds.width - 32), height: Self.emptyHeight)
            empty.autoresizingMask = [.width]
            view.contentView?.addSubview(empty)
            emptyLabel = empty
        } else {
            for (index, target) in targets.enumerated() {
                let title = "Fallback \(index + 1)"
                let row = BrainTargetRowView(
                    title: title,
                    status: target == activeTarget ? "Active this session" : nil,
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
                        canMoveDown: index < targets.count - 1,
                        moveUp: { [weak self] in self?.move(from: index, offset: -1) },
                        moveDown: { [weak self] in self?.move(from: index, offset: 1) },
                        remove: { [weak self] in self?.remove(at: index) }),
                    onProviderChanged: { [weak self] provider in
                        self?.changeProvider(at: index, to: provider)
                    },
                    onModelChanged: { [weak self] model in
                        self?.changeModel(at: index, to: model)
                    })
                row.frame = NSRect(
                    x: 16,
                    y: height - 58 - CGFloat(index + 1) * Self.rowHeight,
                    width: max(200, view.bounds.width - 32),
                    height: Self.rowHeight)
                row.autoresizingMask = [.width]
                view.contentView?.addSubview(row)
                rowViews.append(row)
            }
        }

        addButton.isEnabled = nextAvailableTarget() != nil
        // Rows are rebuilt after the persistent controls. Reinsert the footer controls so the
        // accessibility and keyboard traversal order matches the visible top-to-bottom route.
        if let content = view.contentView {
            for control in [addButton, routeNote, savedFooter, applyFooter] {
                control.removeFromSuperview()
                content.addSubview(control)
            }
        }
        layoutFixedContent()
        onHeightChanged(height)
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
        groupLabel.setAccessibilityLabel("Fallback route")
        view.contentView?.addSubview(groupLabel)

        addButton.target = self
        addButton.action = #selector(addFallback)
        addButton.bezelStyle = .rounded
        addButton.setAccessibilityLabel("Add fallback target")
        view.contentView?.addSubview(addButton)

        routeNote.textColor = .secondaryLabelColor
        routeNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.contentView?.addSubview(routeNote)

        savedFooter.textColor = .secondaryLabelColor
        savedFooter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.contentView?.addSubview(savedFooter)

        applyFooter.alignment = .right
        applyFooter.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        applyFooter.textColor = .secondaryLabelColor
        view.contentView?.addSubview(applyFooter)
    }

    private func layoutFixedContent() {
        let width = view.bounds.width
        let height = preferredHeight
        groupLabel.frame = NSRect(x: 16, y: height - 34, width: width - 32, height: 18)
        addButton.frame = NSRect(x: 12, y: 91, width: 132, height: 32)
        routeNote.frame = NSRect(x: 16, y: 43, width: width - 32, height: 42)
        savedFooter.frame = NSRect(x: 16, y: 16, width: (width - 40) / 2, height: 18)
        applyFooter.frame = NSRect(
            x: width / 2, y: 16, width: width / 2 - 16, height: 18)

        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(
                x: 16,
                y: height - 58 - CGFloat(index + 1) * Self.rowHeight,
                width: width - 32,
                height: Self.rowHeight)
        }
        emptyLabel?.frame = NSRect(
            x: 16, y: height - 92, width: width - 32, height: Self.emptyHeight)
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
