import AppKit
import JarvisCore
import UniformTypeIdentifiers

/// Settings → Tools: the coaching tools the user can switch. Prep notes search is the only one, and
/// its source list lives with it, shown only while the tool is on.
///
/// Jarvis stores only the chosen paths, never a copy, and reads them fresh when needed, so removing a
/// source only forgets it. The switch writes `BrainPreferences.disabledTools` and nothing else; a
/// session reads its capabilities once at Start. The switch is always enabled, but the runtime offers
/// `search_prep_notes` only when sources exist, which is why its detail asks for notes while the list
/// is empty.
@MainActor
final class ToolsSection: NSObject, SettingsSection {
    let destination = SettingsDestination.tools

    private static let switchRowHeight: CGFloat = 62
    private static let sourceRowHeight: CGFloat = 52
    private static let messageRowHeight: CGFloat = 44
    private static let addRowHeight: CGFloat = 46

    /// What the file picker accepts: the formats prep indexing can read. `UTType(filenameExtension:)`
    /// synthesizes a type for ".md" and ".docx", which have no dedicated system UTI. Folders are
    /// unfiltered; their contents are filtered by the same list at indexing time.
    private static let allowedContentTypes: [UTType] = [
        .plainText, .pdf, UTType(filenameExtension: "md"), UTType(filenameExtension: "docx"),
    ].compactMap { $0 }

    private let brainPreferences: BrainPreferences
    private let prepPreferences: PrepMaterialPreferences
    private var stack: SettingsCardStack?
    private var card: SettingsCardView?
    private let prepSwitch = NSSwitch()
    /// Built once per page so the switch is never re-parented while it is being toggled.
    private var switchRow: SettingsRowView?
    private let addButton = NSButton(title: "＋ Add files or folders…", target: nil, action: nil)
    /// Everything below the switch row, rebuilt on each render.
    private var listViews: [NSView] = []
    private var rowsBySourceID: [UUID: SettingsRowView] = [:]
    /// Guards a background existence check against a stale result landing after a newer render.
    private var renderGeneration = 0

    init(brainPreferences: BrainPreferences, prepPreferences: PrepMaterialPreferences) {
        self.brainPreferences = brainPreferences
        self.prepPreferences = prepPreferences
        super.init()
        prepSwitch.target = self
        prepSwitch.action = #selector(prepSwitchChanged)
        prepSwitch.setAccessibilityLabel("Search my prep notes")
        prepSwitch.identifier = NSUserInterfaceItemIdentifier("tool-search-prep-notes")
        addButton.target = self
        addButton.action = #selector(addSource)
        addButton.bezelStyle = .rounded
        addButton.setAccessibilityLabel("Add prep notes")
    }

    private var isPrepSearchOn: Bool {
        !brainPreferences.disabledTools.contains(searchPrepNotesTool.name)
    }

    private var cardHeight: CGFloat {
        let list: CGFloat
        if isPrepSearchOn {
            let count = prepPreferences.sources.count
            list = (count == 0 ? Self.messageRowHeight : CGFloat(count) * Self.sourceRowHeight)
                + Self.addRowHeight
        } else {
            list = Self.messageRowHeight
        }
        return SettingsStyle.cardHeaderHeight + Self.switchRowHeight + list
    }

    func makePage() -> SettingsPageView {
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: cardHeight))
        card.setHeader(title: "Prep notes search", detail: "Local only, never uploaded")
        card.onLayout = { [weak self] in self?.layoutCard() }
        self.card = card
        let switchRow = SettingsRowView(
            title: "Search my prep notes",
            detail: "",
            controlView: prepSwitch,
            controlSize: NSSize(width: 44, height: 26),
            preferredHeight: Self.switchRowHeight,
            // The card header already draws the line above the first row.
            showsSeparator: false)
        card.contentView?.addSubview(switchRow)
        self.switchRow = switchRow

        let callout = SettingsCalloutView(text: "I only read these files. I never copy, edit, or "
            + "upload them, and removing one here doesn't delete it.")
        let stack = SettingsCardStack()
        stack.install([(card, cardHeight), (callout, SettingsCalloutView.preferredHeight)])
        self.stack = stack
        render()
        return SettingsPageView(
            title: "Tools",
            summary: "Extra things I can reach for while coaching.",
            chip: .neutral("Applies next start"),
            bodyView: stack.scrollView)
    }

    func didBecomeActive() {
        // A source may have moved or been deleted since the page was last open.
        render()
    }

    func windowWillClose() {
        listViews.removeAll()
        rowsBySourceID.removeAll()
        switchRow = nil
        card = nil
        stack = nil
    }

    private func render() {
        guard let card, let content = card.contentView else { return }
        renderGeneration += 1
        let generation = renderGeneration
        listViews.forEach { $0.removeFromSuperview() }
        listViews.removeAll()
        rowsBySourceID.removeAll()

        let isOn = isPrepSearchOn
        let sources = prepPreferences.sources
        prepSwitch.state = isOn ? .on : .off
        switchRow?.setDetail(isOn && sources.isEmpty
            ? "Add notes below and I can search them."
            : "When a topic you prepared comes up, I look it up in these notes.")

        if isOn {
            if sources.isEmpty {
                listViews.append(messageLabel("No notes yet."))
            }
            for source in sources {
                let remove = ClosureButton(title: "×") { [weak self] in
                    self?.prepPreferences.remove(id: source.id)
                    self?.render()
                }
                remove.bezelStyle = .rounded
                remove.controlSize = .small
                remove.setAccessibilityLabel("Remove \(source.displayName)")
                let row = SettingsRowView(
                    title: source.displayName,
                    detail: source.path,
                    controlView: remove,
                    controlSize: NSSize(width: 30, height: 30),
                    preferredHeight: Self.sourceRowHeight)
                listViews.append(row)
                rowsBySourceID[source.id] = row
            }
            listViews.append(addButton)
        } else {
            listViews.append(messageLabel("Switched off. Your list is kept, and I won't search it."))
        }
        listViews.forEach { content.addSubview($0) }
        stack?.setHeight(cardHeight, for: card)
        card.frame.size.height = cardHeight
        layoutCard()

        // Existence is a stat() per source, which can block on a network volume or a sleeping disk,
        // so it never runs on the main thread. A still-current render then marks the missing ones.
        guard isOn, !sources.isEmpty else { return }
        Task.detached(priority: .utility) { [sources] in
            let missing = sources.filter { !$0.exists() }
            await MainActor.run { [weak self] in
                self?.applyMissingState(missing, generation: generation)
            }
        }
    }

    private func applyMissingState(_ missing: [PrepMaterialSource], generation: Int) {
        guard generation == renderGeneration else { return }
        for source in missing {
            rowsBySourceID[source.id]?.setTitleColor(SettingsTheme.amber)
            rowsBySourceID[source.id]?.setDetail("Not found at \(source.path)", color: SettingsTheme.amber)
        }
    }

    private func messageLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = SettingsTheme.mutedText
        return label
    }

    /// Top-down placement inside the card body: the switch row, then the list; each view's height
    /// comes from its role.
    private func layoutCard() {
        guard let card else { return }
        let body = card.bodyFrame
        var top = body.maxY
        var views: [NSView] = listViews
        if let switchRow { views.insert(switchRow, at: 0) }
        for view in views {
            let height: CGFloat
            switch view {
            case let row as SettingsRowView: height = row.preferredHeight
            case addButton: height = Self.addRowHeight
            default: height = Self.messageRowHeight
            }
            top -= height
            switch view {
            case addButton:
                view.frame = NSRect(x: SettingsStyle.rowHorizontalInset, y: top + 7, width: 210, height: 32)
            case is SettingsRowView:
                view.frame = NSRect(x: 0, y: top, width: body.width, height: height)
            default:
                view.frame = NSRect(
                    x: SettingsStyle.rowHorizontalInset, y: top + 13,
                    width: max(0, body.width - SettingsStyle.rowHorizontalInset * 2), height: 18)
            }
        }
    }

    @objc private func prepSwitchChanged(_ sender: NSSwitch) {
        var disabled = brainPreferences.disabledTools
        if sender.state == .on {
            disabled.remove(searchPrepNotesTool.name)
        } else {
            disabled.insert(searchPrepNotesTool.name)
        }
        brainPreferences.disabledTools = disabled
        jlog("Jarvis: prep notes search \(sender.state == .on ? "on" : "off") for the next Start.")
        render()
    }

    @objc private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose notes I can reference while coaching. Files stay where they are."
        guard panel.runModal() == .OK else { return } // ghost-mode-allowed: explicit user action in Settings

        var newSources: [PrepMaterialSource] = []
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            newSources.append(PrepMaterialSource(path: url.path, isDirectory: isDirectory.boolValue))
        }
        prepPreferences.add(newSources)
        render()
    }
}
