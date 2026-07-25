import AppKit
import JarvisCore

/// One provider/model target row shared by Primary and fallbacks in the unified Provider card.
///
/// The row owns only presentation and discrete control callbacks. Primary-route persistence,
/// fallback-list mutation, availability policy, and runtime state remain with their existing owners.
@MainActor
final class BrainTargetRowView: NSView {
    struct Actions {
        let canMoveUp: Bool
        let canMoveDown: Bool
        let moveUp: () -> Void
        let moveDown: () -> Void
        let remove: () -> Void
    }

    private let titleLabel: NSTextField
    private let statusLabel: NSTextField?
    private let providerPopup: NSPopUpButton
    private let modelPopup: NSPopUpButton
    private let trailingView: NSView?
    private let providerIndexOffset: Int
    private let models: [BrainModel]
    private let onProviderChanged: (BrainProvider) -> Void
    private let onModelChanged: (BrainModel) -> Void

    init(
        title: String,
        status: String? = nil,
        target: BrainTarget?,
        providerTitle: (BrainProvider) -> String,
        canSelectProvider: (BrainProvider) -> Bool,
        canSelectModel: (BrainModel) -> Bool,
        trailingBadge: String? = nil,
        actions: Actions? = nil,
        onProviderChanged: @escaping (BrainProvider) -> Void,
        onModelChanged: @escaping (BrainModel) -> Void
    ) {
        precondition(trailingBadge == nil || actions == nil)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .left
        self.titleLabel = titleLabel

        if let status {
            let label = NSTextField(labelWithString: status.uppercased())
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize - 1)
            label.textColor = .controlAccentColor
            self.statusLabel = label
        } else {
            self.statusLabel = nil
        }

        let providerPopup = NSPopUpButton()
        providerPopup.menu?.autoenablesItems = false
        if target == nil {
            providerPopup.addItem(withTitle: "Choose provider…")
        }
        providerPopup.addItems(withTitles: BrainProvider.allCases.map(providerTitle))
        let providerIndexOffset = target == nil ? 1 : 0
        self.providerIndexOffset = providerIndexOffset
        if let target {
            providerPopup.selectItem(
                at: (BrainProvider.allCases.firstIndex(of: target.provider) ?? 0)
                    + providerIndexOffset)
        } else {
            providerPopup.selectItem(at: 0)
        }
        providerPopup.setAccessibilityLabel("\(title) provider")
        for (index, provider) in BrainProvider.allCases.enumerated() {
            providerPopup.item(at: index + providerIndexOffset)?.isEnabled =
                provider == target?.provider || canSelectProvider(provider)
        }
        self.providerPopup = providerPopup

        let models = target.map { BrainModelCatalog.models(for: $0.provider) } ?? []
        self.models = models
        let modelPopup = NSPopUpButton()
        modelPopup.menu?.autoenablesItems = false
        if let target {
            modelPopup.addItems(withTitles: models.map(\.displayName))
            if let selected = models.firstIndex(where: { $0.id == target.modelID }) {
                modelPopup.selectItem(at: selected)
            }
        } else {
            modelPopup.addItem(withTitle: "Choose model…")
            modelPopup.isEnabled = false
        }
        modelPopup.setAccessibilityLabel("\(title) model")
        for (index, model) in models.enumerated() {
            modelPopup.item(at: index)?.isEnabled =
                model.id == target?.modelID || canSelectModel(model)
        }
        self.modelPopup = modelPopup

        if let trailingBadge {
            let badge = NSTextField(labelWithString: trailingBadge)
            badge.alignment = .center
            badge.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize - 1)
            badge.textColor = .controlAccentColor
            badge.drawsBackground = true
            badge.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 9
            badge.layer?.masksToBounds = true
            badge.setAccessibilityLabel(trailingBadge)
            self.trailingView = badge
        } else if let actions {
            // Start at its final frame size so AppKit never solves the button constraints against
            // a transient zero-sized stack while the Provider card is being assembled.
            let controls = NSStackView(
                frame: NSRect(x: 0, y: 0, width: 98, height: 32))
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 4

            let moveUp = Self.actionButton(
                title: "↑", label: "Move \(title) up",
                enabled: actions.canMoveUp, action: actions.moveUp)
            let moveDown = Self.actionButton(
                title: "↓", label: "Move \(title) down",
                enabled: actions.canMoveDown, action: actions.moveDown)
            let remove = Self.actionButton(
                title: "×", label: "Remove \(title)",
                enabled: true, action: actions.remove)
            controls.addArrangedSubview(moveUp)
            controls.addArrangedSubview(moveDown)
            controls.addArrangedSubview(remove)
            self.trailingView = controls
        } else {
            self.trailingView = nil
        }

        self.onProviderChanged = onProviderChanged
        self.onModelChanged = onModelChanged

        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 52))

        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        addSubview(titleLabel)
        if let statusLabel { addSubview(statusLabel) }
        addSubview(providerPopup)
        addSubview(modelPopup)
        if let trailingView { addSubview(trailingView) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        // Matches the selected mock's compact label column; the optional "IN USE" marker fits below.
        let labelWidth: CGFloat = 92
        let gap: CGFloat = 9
        let actionsWidth: CGFloat = trailingView == nil ? 0 : 98
        let actionsGap: CGFloat = trailingView == nil ? 0 : gap
        let selectionWidth = max(
            225,
            bounds.width - labelWidth - gap - actionsWidth - actionsGap)
        let popupWidth = max(108, (selectionWidth - gap) / 2)

        if statusLabel == nil {
            titleLabel.frame = NSRect(x: 0, y: 16, width: labelWidth, height: 20)
        } else {
            titleLabel.frame = NSRect(x: 0, y: 27, width: labelWidth, height: 20)
            statusLabel?.frame = NSRect(x: 0, y: 8, width: labelWidth, height: 15)
        }

        let providerX = labelWidth + gap
        providerPopup.frame = NSRect(x: providerX, y: 10, width: popupWidth, height: 32)
        let modelX = providerPopup.frame.maxX + gap
        modelPopup.frame = NSRect(x: modelX, y: 10, width: popupWidth, height: 32)
        trailingView?.frame = NSRect(
            x: bounds.width - actionsWidth, y: 10, width: actionsWidth, height: 32)
    }

    private static func actionButton(
        title: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - providerIndexOffset
        guard BrainProvider.allCases.indices.contains(index) else { return }
        onProviderChanged(BrainProvider.allCases[index])
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard models.indices.contains(index) else { return }
        onModelChanged(models[index])
    }
}

/// A tiny target/action adapter used only by the icon buttons in `BrainTargetRowView`.
@MainActor
private final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        closure()
    }
}
