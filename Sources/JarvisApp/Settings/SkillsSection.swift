import AppKit
import JarvisCore

/// Settings → Skills: one card per bundled coaching skill, each switched on or off for the next
/// Start. A card's text is the skill file's own `description`, so there is one source for it. Writes
/// go to `BrainPreferences.disabledSkills` and nothing else; a session reads its skills once at Start.
@MainActor
final class SkillsSection: NSObject, SettingsSection {
    let destination = SettingsDestination.skills

    private let preferences: BrainPreferences

    init(preferences: BrainPreferences) {
        self.preferences = preferences
    }

    func makePage() -> SettingsPageView {
        // Read when the page is built: the same granularity as the Start the switches apply at.
        let skills = SkillCatalog.bundled()
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 712, height: 432))

        let cards = skills.map { skill in
            SkillCardView(
                skill: skill,
                isOn: !preferences.disabledSkills.contains(skill.name),
                onToggle: { [weak self] isOn in self?.setSkill(skill.name, isOn: isOn) })
        }
        let grid = SkillCardGridView(cards: cards)
        let scroll = SettingsScrollView(frame: NSRect(x: 0, y: 0, width: 712, height: 400))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid
        scroll.onViewportChanged = { [weak grid, weak scroll] in
            guard let grid, let scroll else { return }
            grid.fit(
                width: scroll.contentView.bounds.width,
                minimumHeight: scroll.contentView.bounds.height)
        }
        body.addSubview(scroll)

        var constraints = [
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ]
        if skills.isEmpty {
            let caption = NSTextField(labelWithString: "No skills are installed.")
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = SettingsTheme.mutedText
            caption.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(caption)
            constraints += [
                caption.topAnchor.constraint(equalTo: body.topAnchor),
                caption.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
            ]
        } else {
            constraints.append(scroll.topAnchor.constraint(equalTo: body.topAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return SettingsPageView(
            title: "Skills",
            summary: "Coaching know-how I load when a matching question comes up.",
            chip: .neutral("Applies next start"),
            bodyView: body)
    }

    private func setSkill(_ name: String, isOn: Bool) {
        var disabled = preferences.disabledSkills
        if isOn { disabled.remove(name) } else { disabled.insert(name) }
        preferences.disabledSkills = disabled
        jlog("Jarvis: \(name) skill \(isOn ? "on" : "off") for the next Start.")
    }
}
