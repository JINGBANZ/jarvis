import AppKit
import JarvisCore

@MainActor
final class BrainTargetRowView: NSView {
    struct Actions {
        let canMoveUp: Bool
        let canMoveDown: Bool
        let moveUp: () -> Void
        let moveDown: () -> Void
        /// Nil for the primary: a route always has one.
        let remove: (() -> Void)?
    }

    private let titleLabel: NSTextField
    private let statusLabel: NSTextField?
    private let providerPopup: NSPopUpButton
    private let providers: [BrainProvider]
    private let modelPopup: NSPopUpButton
    private let actionsView: NSView?
    private let models: [BrainModel]
    private let onProviderChanged: (BrainProvider) -> Void
    private let onModelChanged: (BrainModel) -> Void

    let preferredHeight: CGFloat

    init(
        title: String,
        status: String? = nil,
        target: BrainTarget,
        canSelectProvider: (BrainProvider) -> Bool,
        canSelectModel: (BrainModel) -> Bool,
        actions: Actions? = nil,
        onProviderChanged: @escaping (BrainProvider) -> Void,
        onModelChanged: @escaping (BrainModel) -> Void
    ) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = SettingsTheme.text
        titleLabel.alignment = .left
        self.titleLabel = titleLabel

        if let status {
            // A layer border doesn't follow the appearance, so `applyStatusBorder()` reapplies it.
            let label = NSTextField(labelWithString: status.uppercased())
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize - 1)
            label.textColor = SettingsTheme.teal
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.cornerRadius = 5
            label.layer?.borderWidth = 1
            self.statusLabel = label
        } else {
            self.statusLabel = nil
        }

        let providerPopup = NSPopUpButton()
        providerPopup.menu?.autoenablesItems = false
        let providers = BrainProvider.allCases.filter {
            $0 == target.provider || canSelectProvider($0)
        }
        self.providers = providers
        providerPopup.addItems(withTitles: providers.map(\.displayName))
        if let selected = providers.firstIndex(of: target.provider) {
            providerPopup.selectItem(at: selected)
        }
        providerPopup.setAccessibilityLabel("\(title) provider")
        for (index, provider) in providers.enumerated() {
            providerPopup.item(at: index)?.isEnabled =
                provider == target.provider || canSelectProvider(provider)
        }
        self.providerPopup = providerPopup

        let models = BrainModelCatalog.models(for: target.provider)
        self.models = models
        let modelPopup = NSPopUpButton()
        modelPopup.menu?.autoenablesItems = false
        modelPopup.addItems(withTitles: models.map(\.displayName))
        if let selected = models.firstIndex(where: { $0.id == target.modelID }) {
            modelPopup.selectItem(at: selected)
        }
        modelPopup.setAccessibilityLabel("\(title) model")
        for (index, model) in models.enumerated() {
            modelPopup.item(at: index)?.isEnabled =
                model.id == target.modelID || canSelectModel(model)
        }
        self.modelPopup = modelPopup

        if let actions {
            // Start at the final size so AppKit never solves the button constraints against a
            // transient zero-sized stack.
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
                enabled: actions.remove != nil, action: actions.remove ?? {})
            // The primary has no ×, but keeps its slot so its ↑ and ↓ line up with the fallbacks'.
            remove.isHidden = actions.remove == nil
            controls.detachesHiddenViews = false
            controls.addArrangedSubview(moveUp)
            controls.addArrangedSubview(moveDown)
            controls.addArrangedSubview(remove)
            self.actionsView = controls
            self.preferredHeight = 84
        } else {
            self.actionsView = nil
            self.preferredHeight = 54
        }

        self.onProviderChanged = onProviderChanged
        self.onModelChanged = onModelChanged

        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: preferredHeight))

        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        addSubview(titleLabel)
        if let statusLabel { addSubview(statusLabel) }
        addSubview(providerPopup)
        addSubview(modelPopup)
        if let actionsView { addSubview(actionsView) }
        applyStatusBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let labelWidth: CGFloat = 92
        let gap: CGFloat = 9
        let selectionWidth = max(225, bounds.width - labelWidth - gap)
        let popupWidth = max(108, (selectionWidth - gap) / 2)
        let selectionY = bounds.height - 42

        if let statusLabel {
            titleLabel.frame = NSRect(
                x: 0, y: selectionY + 14, width: labelWidth, height: 18)
            let tagWidth = min(labelWidth, ceil(statusLabel.fittingSize.width) + 4)
            statusLabel.frame = NSRect(
                x: 0, y: selectionY - 1, width: tagWidth, height: 15)
        } else {
            titleLabel.frame = NSRect(
                x: 0, y: selectionY + 6, width: labelWidth, height: 20)
        }

        let providerX = labelWidth + gap
        providerPopup.frame = NSRect(
            x: providerX, y: selectionY, width: popupWidth, height: 32)
        let modelX = providerPopup.frame.maxX + gap
        modelPopup.frame = NSRect(
            x: modelX, y: selectionY, width: popupWidth, height: 32)

        actionsView?.frame = NSRect(x: bounds.width - 98, y: 3, width: 98, height: 32)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStatusBorder()
    }

    private func applyStatusBorder() {
        statusLabel?.layer?.borderColor = themedCGColor(SettingsTheme.teal)
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
        let index = sender.indexOfSelectedItem
        guard providers.indices.contains(index) else { return }
        onProviderChanged(providers[index])
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard models.indices.contains(index) else { return }
        onModelChanged(models[index])
    }
}
