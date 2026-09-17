import AppKit
import JarvisCore

@MainActor
enum ActivityExportSheet {
    static func present(sessions: [SessionStore.Session], store: SessionStore) {
        guard !sessions.isEmpty else { return }
        let picker = SessionPickerWindow(sessions: sessions)
        var selectedSessions: [SessionStore.Session] = []
        while true {
            guard picker.runModal() else { return } // ghost-mode-allowed: explicit user action in Settings
            selectedSessions = picker.selectedSessions
            guard selectedSessions.isEmpty else { break }
            inform("Select at least one session",
                   "Choose at least one session to export, then click Export again.")
        }
        let format = picker.selectedFormat
        let includeScreenshots = picker.includeScreenshots
        let jarvisResponsesOnly = picker.jarvisResponsesOnly

        let panel = NSOpenPanel() // ghost-mode-allowed: explicit user action in Settings
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a destination folder for the exported session history."
        guard panel.runModal() == .OK, let destination = panel.url else { return } // ghost-mode-allowed: explicit user action in Settings

        do {
            for session in selectedSessions {
                try write(
                    session: session, store: store, format: format,
                    includeScreenshots: includeScreenshots, jarvisResponsesOnly: jarvisResponsesOnly,
                    into: destination)
            }
            inform("Export complete", "Exported \(selectedSessions.count) "
                + "session\(selectedSessions.count == 1 ? "" : "s") to \(destination.path).")
        } catch {
            inform("Couldn't export history", error.localizedDescription)
        }
    }

    private static func write(
        session: SessionStore.Session,
        store: SessionStore,
        format: ActivityHistoryExporter.ExportFormat,
        includeScreenshots: Bool,
        jarvisResponsesOnly: Bool,
        into destination: URL
    ) throws {
        let export = ActivityHistoryExporter.export(
            session: session, entries: store.entries(for: session), format: format,
            includeScreenshots: includeScreenshots, jarvisResponsesOnly: jarvisResponsesOnly)
        let sessionDir = destination.appendingPathComponent(session.id)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try export.text.write(
            to: sessionDir.appendingPathComponent(export.filename), atomically: true, encoding: .utf8)
        guard !export.images.isEmpty else { return }
        let imagesDir = sessionDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        for (relativePath, data) in export.images {
            let name = (relativePath as NSString).lastPathComponent
            try data.write(to: imagesDir.appendingPathComponent(name))
        }
    }

    private static func inform(_ title: String, _ message: String) {
        let alert = NSAlert() // ghost-mode-allowed: explicit user action in Settings
        alert.messageText = title
        alert.informativeText = message
        alert.runModal() // ghost-mode-allowed: explicit user action in Settings
    }
}

@MainActor
private final class SessionPickerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate {
    private let sessions: [SessionStore.Session]
    private var checkedRows: [Bool]
    private let window: NSWindow
    private let tableView = NSTableView()
    private var formatButtons: [(NSButton, ActivityHistoryExporter.ExportFormat)] = []
    private let screenshotsCheckbox =
        NSButton(checkboxWithTitle: "Include screenshots", target: nil, action: nil)
    private let responsesOnlyCheckbox =
        NSButton(checkboxWithTitle: "Jarvis responses only", target: nil, action: nil)
    private var confirmed = false

    var selectedSessions: [SessionStore.Session] {
        zip(sessions, checkedRows).filter(\.1).map(\.0)
    }
    var selectedFormat: ActivityHistoryExporter.ExportFormat {
        formatButtons.first { $0.0.state == .on }?.1 ?? .markdown
    }
    var includeScreenshots: Bool { screenshotsCheckbox.state == .on }
    var jarvisResponsesOnly: Bool { responsesOnlyCheckbox.state == .on }

    init(sessions: [SessionStore.Session]) {
        self.sessions = sessions
        self.checkedRows = Array(repeating: false, count: sessions.count)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Export Activity History"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        let content = makeContentView()
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 380, height: content.fittingSize.height))
    }

    /// Blocks until the window closes. Returns whether the user chose Export.
    func runModal() -> Bool {
        window.center()
        NSApp.runModal(for: window) // ghost-mode-allowed: explicit user action in Settings
        window.orderOut(nil)
        return confirmed
    }

    private func makeContentView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 440))
        content.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        let formatStack = NSStackView()
        formatStack.orientation = .horizontal
        formatStack.spacing = 12
        let formats: [(String, ActivityHistoryExporter.ExportFormat)] =
            [("Markdown", .markdown), ("Plain text", .plainText), ("HTML", .html)]
        for (title, format) in formats {
            let radio = NSButton(
                radioButtonWithTitle: title, target: self, action: #selector(formatRadioTapped(_:)))
            formatStack.addArrangedSubview(radio)
            formatButtons.append((radio, format))
        }
        formatButtons[0].0.state = .on

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let exportButton = NSButton(title: "Export", target: self, action: #selector(exportTapped))
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [cancelButton, exportButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let root = NSStackView(views: [
            Self.sectionLabel("Sessions to export"), scrollView,
            Self.sectionLabel("Format"), formatStack,
            screenshotsCheckbox, responsesOnlyCheckbox, buttonRow,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 380),
            scrollView.heightAnchor.constraint(equalToConstant: 180),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        return content
    }

    @objc private func exportTapped() {
        confirmed = true
        NSApp.stopModal()
    }

    @objc private func cancelTapped() {
        confirmed = false
        NSApp.stopModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelTapped()
        return true
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("session-checkbox")
        let checkbox = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSButton)
            ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(sessionCheckboxToggled(_:)))
        checkbox.identifier = identifier
        let session = sessions[row]
        checkbox.title = session.isCurrent ? "\(session.label) (current)" : session.label
        checkbox.tag = row
        checkbox.state = checkedRows[row] ? .on : .off
        return checkbox
    }

    @objc private func sessionCheckboxToggled(_ sender: NSButton) {
        checkedRows[sender.tag] = sender.state == .on
    }

    @objc private func formatRadioTapped(_ sender: NSButton) {
        for (button, _) in formatButtons {
            button.state = button === sender ? .on : .off
        }
    }

    private static func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }
}
