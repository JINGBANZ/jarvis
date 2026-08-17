import AppKit
import JarvisCore

/// Compact multi-select control for the expected-language list in Transcription Settings.
@MainActor
final class ExpectedLanguagePicker: NSView {
    private var selectedLanguages: [OpenAITranscriptionLanguage]
    private let onChange: ([OpenAITranscriptionLanguage]) -> Void
    private let chipStack = NSStackView()
    private let editButton = NSButton()
    private let popover = NSPopover()
    private var optionButtons: [NSButton] = []
    private var usesCompactSummary = false

    init(
        selectedLanguages: [OpenAITranscriptionLanguage],
        onChange: @escaping ([OpenAITranscriptionLanguage]) -> Void
    ) {
        self.selectedLanguages = OpenAITranscriptionLanguage.canonicalizing(selectedLanguages)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 32))

        chipStack.orientation = .horizontal
        chipStack.alignment = .centerY
        chipStack.distribution = .gravityAreas
        chipStack.spacing = 6
        chipStack.wantsLayer = true
        chipStack.layer?.masksToBounds = true
        addSubview(chipStack)

        editButton.title = "Edit"
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(showOptions)
        editButton.setAccessibilityLabel("Edit expected transcription languages")
        addSubview(editButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Expected transcription languages")
        buildPopover()
        renderSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let buttonWidth = max(50, ceil(editButton.fittingSize.width))
        editButton.frame = NSRect(
            x: max(0, bounds.width - buttonWidth),
            y: 0,
            width: buttonWidth,
            height: 32)
        let availableChipWidth = max(0, editButton.frame.minX - 8)
        let chipWidth = min(availableChipWidth, ceil(chipStack.fittingSize.width))
        chipStack.frame = NSRect(
            x: availableChipWidth - chipWidth,
            y: 4,
            width: chipWidth,
            height: 24)

        let shouldUseCompactSummary = bounds.width < 290
        if shouldUseCompactSummary != usesCompactSummary {
            usesCompactSummary = shouldUseCompactSummary
            renderSelection()
        }
    }

    private func buildPopover() {
        let rowHeight: CGFloat = 28
        let height = 48 + CGFloat(OpenAITranscriptionLanguage.allCases.count) * rowHeight
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: height))

        let heading = NSTextField(labelWithString: "Expected languages")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.frame = NSRect(x: 16, y: height - 32, width: 268, height: 20)
        controller.view.addSubview(heading)

        var y = height - 62
        for (index, language) in OpenAITranscriptionLanguage.allCases.enumerated() {
            let option = NSButton(
                checkboxWithTitle: language.displayName,
                target: self,
                action: #selector(languageToggled))
            option.tag = index
            option.frame = NSRect(x: 14, y: y, width: 270, height: 22)
            option.setAccessibilityLabel(language.displayName)
            controller.view.addSubview(option)
            optionButtons.append(option)
            y -= rowHeight
        }

        popover.behavior = .transient
        popover.contentSize = controller.view.frame.size
        popover.contentViewController = controller
    }

    private func renderSelection() {
        for view in chipStack.arrangedSubviews {
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let labels: [String]
        if selectedLanguages.isEmpty {
            labels = ["Automatic"]
        } else if usesCompactSummary && selectedLanguages.count > 1 {
            labels = ["\(selectedLanguages.count) selected"]
        } else if selectedLanguages.count > 2 {
            labels = [selectedLanguages[0].displayName, "+\(selectedLanguages.count - 1)"]
        } else {
            labels = selectedLanguages.map(\.displayName)
        }
        for label in labels {
            chipStack.addArrangedSubview(makeChip(label, isAutomatic: selectedLanguages.isEmpty))
        }

        for (index, language) in OpenAITranscriptionLanguage.allCases.enumerated() {
            optionButtons[index].state = selectedLanguages.contains(language) ? .on : .off
        }
        setAccessibilityValue(selectedLanguages.isEmpty
            ? "Automatic"
            : selectedLanguages.map(\.displayName).joined(separator: ", "))
        needsLayout = true
    }

    private func makeChip(_ title: String, isAutomatic: Bool) -> NSTextField {
        let chip = NSTextField(labelWithString: title)
        chip.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        chip.textColor = isAutomatic ? .secondaryLabelColor : .controlAccentColor
        chip.alignment = .center
        chip.drawsBackground = true
        chip.backgroundColor = isAutomatic
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.08)
            : NSColor.controlAccentColor.withAlphaComponent(0.10)
        chip.sizeToFit()
        chip.frame.size = NSSize(width: ceil(chip.frame.width) + 14, height: 24)
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        return chip
    }

    @objc private func showOptions() {
        renderSelection()
        popover.show(relativeTo: editButton.bounds, // ghost-mode-allowed: explicit Settings action
                     of: editButton,
                     preferredEdge: .maxY)
    }

    @objc private func languageToggled(_ sender: NSButton) {
        guard OpenAITranscriptionLanguage.allCases.indices.contains(sender.tag) else { return }
        let language = OpenAITranscriptionLanguage.allCases[sender.tag]
        if sender.state == .on {
            selectedLanguages.append(language)
        } else {
            selectedLanguages.removeAll { $0 == language }
        }
        selectedLanguages = OpenAITranscriptionLanguage.canonicalizing(selectedLanguages)
        renderSelection()
        onChange(selectedLanguages)
    }
}
