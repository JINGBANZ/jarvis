import AppKit
import JarvisCore

/// The Capabilities card in Brain Settings: what the coach can do, and which parts of it the user
/// wants offered.
///
/// Writes go straight to `preferences.disabledTools` / `preferences.disabledSkills` and nothing
/// else. A session resolves its capabilities once at Start, and both the coach loop and a warmed
/// local-agent process are built from that one value, so a mid-session change could only make them
/// disagree — which is why this card never calls the reapply path and says so in its header.
@MainActor
final class CapabilitiesControls: NSObject {
    private let preferences: BrainPreferences
    private let prepMaterialPreferences: PrepMaterialPreferences
    /// Read once, with the rest of the card's inputs: the same granularity as the Start the
    /// switches apply at.
    private let skills = SkillCatalog.bundled()

    private var card: SettingsCardView?
    private var rows: [SettingsRowView] = []

    var preferredHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + CGFloat(max(rows.count, rowCount))
            * SettingsStyle.rowHeight
    }

    /// Three always-on tools, prep-notes search, and one row per bundled skill. Read before
    /// `makeView` runs, when `rows` is still empty, so the card reserves its real height from the
    /// first layout pass.
    private var rowCount: Int { 4 + skills.count }

    init(preferences: BrainPreferences, prepMaterialPreferences: PrepMaterialPreferences) {
        self.preferences = preferences
        self.prepMaterialPreferences = prepMaterialPreferences
    }

    func makeView() -> NSView {
        let card = SettingsCardView(
            frame: NSRect(x: 0, y: 0, width: 712, height: preferredHeight))
        card.setHeader(title: "Capabilities", detail: "Applies on the next Start")
        card.onLayout = { [weak self] in self?.layoutRows() }
        self.card = card
        guard let content = card.contentView else { return card }

        rows = []
        for tool in [captureScreenTool, speakTool, staySilentTool] {
            // A control-less row still needs a control view; the shared row type owns the rhythm.
            let row = SettingsRowView(
                title: Self.title(for: tool.name),
                detail: "Always on",
                controlView: NSView())
            content.addSubview(row)
            rows.append(row)
        }

        let hasPrepSource = !prepMaterialPreferences.sources.isEmpty
        let prepSwitch = NSSwitch()
        prepSwitch.state = preferences.disabledTools.contains(searchPrepNotesTool.name)
            ? .off : .on
        prepSwitch.isEnabled = hasPrepSource
        prepSwitch.target = self
        prepSwitch.action = #selector(prepNotesSearchChanged)
        prepSwitch.setAccessibilityLabel("Prep notes search")
        prepSwitch.identifier = NSUserInterfaceItemIdentifier("capability-search-prep-notes")
        // Read once, when the card is built: adding a source in Prep material enables the switch
        // the next time Settings opens, which is the same granularity as the Start it applies at.
        let prepRow = SettingsRowView(
            title: Self.title(for: searchPrepNotesTool.name),
            detail: hasPrepSource
                ? "Loads on demand when a prepared topic comes up"
                : "Add a prep material source to enable",
            controlView: prepSwitch,
            // The row stretches its control to `controlWidth`; a switch keeps its own size and sits
            // at the trailing edge, as the Shortcuts toggles do.
            controlSize: NSSize(width: 44, height: 26),
            showsSeparator: !skills.isEmpty)
        content.addSubview(prepRow)
        rows.append(prepRow)

        // A switched-off skill keeps its row: nothing is hidden, so it can be switched back on.
        for (index, skill) in skills.enumerated() {
            let toggle = NSSwitch()
            toggle.state = preferences.disabledSkills.contains(skill.name) ? .off : .on
            toggle.tag = index
            toggle.target = self
            toggle.action = #selector(skillChanged)
            toggle.setAccessibilityLabel(Self.title(for: skill))
            toggle.identifier = NSUserInterfaceItemIdentifier("capability-skill-\(skill.name)")
            let row = SettingsRowView(
                title: Self.title(for: skill),
                detail: "Loaded when a matching question comes up",
                controlView: toggle,
                controlSize: NSSize(width: 44, height: 26),
                showsSeparator: index < skills.count - 1)
            content.addSubview(row)
            rows.append(row)
        }

        layoutRows()
        return card
    }

    /// "system-design" reads as "System design": the skill's own name, in sentence case.
    private static func title(for skill: Skill) -> String {
        skill.name.replacingOccurrences(of: "-", with: " ").prefix(1).uppercased()
            + skill.name.replacingOccurrences(of: "-", with: " ").dropFirst()
    }

    private static func title(for toolName: String) -> String {
        switch toolName {
        case captureScreenTool.name: "Screen capture"
        case speakTool.name: "Speak"
        case staySilentTool.name: "Stay silent"
        case searchPrepNotesTool.name: "Prep notes search"
        default: toolName
        }
    }

    private func layoutRows() {
        guard let card else { return }
        var top = card.bodyFrame.maxY
        for row in rows {
            top -= row.preferredHeight
            row.frame = NSRect(
                x: 0, y: top, width: card.bodyFrame.width, height: row.preferredHeight)
        }
    }

    @objc private func prepNotesSearchChanged(_ sender: NSSwitch) {
        var disabled = preferences.disabledTools
        if sender.state == .on {
            disabled.remove(searchPrepNotesTool.name)
        } else {
            disabled.insert(searchPrepNotesTool.name)
        }
        preferences.disabledTools = disabled
        jlog("Jarvis: prep notes search \(sender.state == .on ? "on" : "off") for the next Start.")
    }

    @objc private func skillChanged(_ sender: NSSwitch) {
        guard skills.indices.contains(sender.tag) else { return }
        let name = skills[sender.tag].name
        var disabled = preferences.disabledSkills
        if sender.state == .on {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        preferences.disabledSkills = disabled
        jlog("Jarvis: \(name) skill \(sender.state == .on ? "on" : "off") for the next Start.")
    }
}
