import AppKit
import JarvisCore

/// Settings → Brain: the provider route and the reasoning effort.
///
/// Provider/model ordering is edited by `ProviderRouteEditor`; shared authentication lives on the
/// Connections page. Which subscriptions are signed in comes from `SubscriptionSignIns`, the answer
/// the hub shows too, and completed preference edits are handed to the running session.
@MainActor
final class BrainSection: NSObject, SettingsSection {
    enum PreferenceChange: Equatable {
        case topology
        case effort
    }

    let destination = SettingsDestination.brain

    private static let effortCardHeight =
        SettingsStyle.cardHeaderHeight + SettingsStyle.rowHeight

    private let preferences: BrainPreferences
    private let signIns: SubscriptionSignIns
    private let onPreferencesChanged: (PreferenceChange) -> Void

    private var stack: SettingsCardStack?
    private var providerEditor: ProviderRouteEditor?
    private var signInObserver: UUID?
    /// Session-local runtime state only. This marker never writes preferences or reorders the route.
    private var activeTarget: BrainTarget?

    init(
        preferences: BrainPreferences,
        signIns: SubscriptionSignIns,
        onPreferencesChanged: @escaping (PreferenceChange) -> Void
    ) {
        self.preferences = preferences
        self.signIns = signIns
        self.onPreferencesChanged = onPreferencesChanged
    }

    func makePage() -> SettingsPageView {
        let stack = SettingsCardStack()
        self.stack = stack
        let providerEditor = ProviderRouteEditor(
            preferences: preferences,
            onChange: { [weak self] in self?.onPreferencesChanged(.topology) },
            onHeightChanged: { [weak self] height in
                guard let self, let editor = self.providerEditor else { return }
                self.stack?.setHeight(height, for: editor.view)
            })
        self.providerEditor = providerEditor
        let effortCard = makeEffortCard()
        stack.install([
            (providerEditor.view, providerEditor.preferredHeight),
            (effortCard, Self.effortCardHeight),
        ])
        signInObserver = signIns.observe { [weak self] in self?.renderRoute() }
        renderRoute()
        return SettingsPageView(
            title: "Brain",
            summary: "Who does my thinking, and how hard I think.",
            chip: .neutral("Applies next attempt"),
            part: .brain,
            bodyView: stack.scrollView)
    }

    /// Reflect the driver's selected runtime target without mutating the saved route.
    func setActiveTarget(_ target: BrainTarget?) {
        activeTarget = target
        renderRoute()
    }

    func didBecomeActive() {
        signIns.refresh()
    }

    func windowWillClose() {
        if let signInObserver { signIns.removeObserver(signInObserver) }
        signInObserver = nil
        stack = nil
        providerEditor = nil
    }

    private func makeEffortCard() -> SettingsCardView {
        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: Self.effortCardHeight))
        card.setHeader(title: "Reasoning effort", detail: "More effort, slower hints")
        guard let content = card.contentView else { return card }

        // Short labels, as in the prototype, so four segments with glyphs fit the row's control
        // width even at the window's 560-point minimum; the tooltip carries the full name.
        let effortControl = NSSegmentedControl(
            labels: ReasoningEffort.allCases.map { $0 == .medium ? "Med" : $0.displayName },
            trackingMode: .selectOne,
            target: self,
            action: #selector(effortChanged))
        effortControl.setAccessibilityLabel("Reasoning effort")
        effortControl.controlSize = .small
        effortControl.segmentDistribution = .fillEqually
        for (index, effort) in ReasoningEffort.allCases.enumerated() {
            effortControl.setImage(Self.effortGlyph(level: index), forSegment: index)
            effortControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
            effortControl.setToolTip(effort.displayName, forSegment: index)
        }
        if let index = ReasoningEffort.allCases.firstIndex(of: preferences.effort) {
            effortControl.selectedSegment = index
        }
        let effortRow = SettingsRowView(
            title: "Effort",
            detail: "Applies to whichever brain is answering.",
            controlView: effortControl,
            controlSize: NSSize(width: 320, height: 28),
            showsSeparator: false)
        content.addSubview(effortRow)

        card.onLayout = { [weak card, weak effortRow] in
            guard let card, let effortRow else { return }
            effortRow.frame = NSRect(
                x: 0, y: card.bodyFrame.maxY - effortRow.preferredHeight,
                width: card.bodyFrame.width, height: effortRow.preferredHeight)
        }
        card.onLayout?()
        return card
    }

    /// `level` filled bars out of three, drawn next to each effort label: the prototype's power bars,
    /// as a template image so the native control tints it.
    private static func effortGlyph(level: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 8), flipped: false) { @Sendable _ in
            for index in 0..<3 {
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: CGFloat(index) * 7 + 0.5, y: 1.5, width: 5, height: 5),
                    xRadius: 1, yRadius: 1)
                if index < level {
                    NSColor.black.setFill()
                    bar.fill()
                } else {
                    NSColor.black.setStroke()
                    bar.lineWidth = 1
                    bar.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func renderRoute() {
        providerEditor?.render(signedInSubscriptions: signIns.selectable, activeTarget: activeTarget)
    }

    @objc private func effortChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard ReasoningEffort.allCases.indices.contains(index) else { return }
        preferences.effort = ReasoningEffort.allCases[index]
        onPreferencesChanged(.effort)
    }
}
