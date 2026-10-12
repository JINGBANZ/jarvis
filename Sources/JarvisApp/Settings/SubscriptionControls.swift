import AppKit
import JarvisBrainProviders
import JarvisCore

@MainActor
final class SubscriptionControls: NSObject {
    static let providers: [BrainProvider] = [.codexSubscription, .claudeSubscription]

    private(set) var preferredHeight = SettingsStyle.cardHeaderHeight
        + CGFloat(SubscriptionControls.providers.count) * SettingsStyle.rowHeight

    private struct Row {
        let view: SettingsRowView
        let buttons: [NSButton]
        var actions: [SubscriptionConnectionState.Action] = []
    }

    private let subscriptionSignIns: SubscriptionSignIns
    private var rows: [BrainProvider: Row] = [:]
    private var card: SettingsCardView?
    private var onHeightChanged: ((CGFloat) -> Void)?
    var onStatusChanged: (() -> Void)?
    var onWillSignOut: ((BrainProvider) -> Void)?

    init(signIns: SubscriptionSignIns) {
        self.subscriptionSignIns = signIns
        super.init()
        signIns.observe { [weak self] in self?.render() }
    }

    func makeView(onHeightChanged: @escaping (CGFloat) -> Void) -> NSView {
        rows.removeAll()
        self.onHeightChanged = onHeightChanged
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        self.card = card
        card.setHeader(title: "Subscriptions", detail: "Use your ChatGPT or Claude plan as my brain")
        guard let content = card.contentView else { return card }

        for (index, provider) in Self.providers.enumerated() {
            let buttons = (0..<2).map { slot in
                let button = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
                button.bezelStyle = .rounded
                button.tag = index * 2 + slot
                let suffix = slot == 0 ? "action" : "sign-out"
                button.identifier = NSUserInterfaceItemIdentifier("\(provider.rawValue)-\(suffix)")
                return button
            }
            let actions = NSStackView(views: buttons)
            actions.orientation = .horizontal
            actions.spacing = 8
            actions.translatesAutoresizingMaskIntoConstraints = false
            let controls = NSView()
            controls.addSubview(actions)
            NSLayoutConstraint.activate([
                actions.leadingAnchor.constraint(greaterThanOrEqualTo: controls.leadingAnchor),
                actions.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
                actions.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            ])
            let row = SettingsRowView(
                title: provider.displayName,
                detail: "Checking…",
                controlView: controls,
                controlSize: NSSize(width: 200, height: 32),
                wrapsDetail: true,
                showsSeparator: index > 0)
            content.addSubview(row)
            rows[provider] = Row(view: row, buttons: buttons)
        }
        card.onLayout = { [weak self] in self?.layout() }
        render()
        return card
    }

    private func layout() {
        guard let card else { return }
        let heights = Self.providers.map {
            rows[$0]?.view.height(for: card.bodyFrame.width) ?? SettingsStyle.rowHeight
        }
        let height = SettingsStyle.cardHeaderHeight + heights.reduce(0, +)
        if preferredHeight != height {
            preferredHeight = height
            onHeightChanged?(height)
        }
        let body = card.bodyFrame
        var top = body.maxY
        for (provider, rowHeight) in zip(Self.providers, heights) {
            top -= rowHeight
            rows[provider]?.view.frame = NSRect(x: body.minX, y: top, width: body.width, height: rowHeight)
        }
    }

    func windowWillClose() {
        card = nil
        rows.removeAll()
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let index = sender.tag / 2
        let slot = sender.tag % 2
        guard Self.providers.indices.contains(index) else { return }
        let provider = Self.providers[index]
        guard let row = rows[provider], row.actions.indices.contains(slot) else { return }
        subscriptionSignIns.perform(row.actions[slot], for: provider, openURL: { url in
            NSWorkspace.shared.open(url) // ghost-mode-allowed: the user pressed Sign in inside Settings
        }, willSignOut: { [weak self] provider in
            self?.onWillSignOut?(provider)
        })
    }

    private func render() {
        for provider in Self.providers {
            guard let row = rows[provider] else { continue }
            let state = subscriptionSignIns.connection(for: provider)
            rows[provider]?.actions = state.buttons.map(\.action)
            for (slot, button) in row.buttons.enumerated() {
                button.isHidden = !state.buttons.indices.contains(slot)
                guard !button.isHidden else { continue }
                let presentation = state.buttons[slot]
                button.title = presentation.title
                button.isEnabled = presentation.isEnabled
                button.setAccessibilityLabel("\(presentation.title) \(provider.displayName)")
            }
            let color: NSColor = switch state.tone {
            case .neutral: SettingsTheme.mutedText
            case .ready: SettingsTheme.teal
            case .attention: SettingsTheme.amber
            }
            row.view.setDetail(state.detail, color: color)
        }
        layout()
        card?.needsLayout = true
        onStatusChanged?()
    }
}
