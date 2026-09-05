import AppKit
import JarvisCore

/// Presents the "Export…" flow for `ActivityViewer`: a scrollable, checkable list of sessions (so
/// an arbitrarily long history never distorts the dialog's layout), an export-format choice, and
/// two content toggles — then a destination-folder panel, then writes one file (plus an
/// `images/` subfolder when applicable) per selected session. The picker window and both panels
/// run as blocking modal loops, the same explicit-user-action style as
/// `PrepMaterialSection.addSource()` and `ActivityViewer`'s own `clearHistoryTapped()`.
@MainActor
enum ActivityExportSheet {
    static func present(sessions: [SessionStore.Session], store: SessionStore) {
        guard !sessions.isEmpty else { return }
        let picker = SessionPickerWindow(sessions: sessions)
        var selectedSessions: [SessionStore.Session] = []
        // Loop on an empty selection: reopen the same picker (preserving whatever format/toggle
        // choices were already made) instead of ending the whole flow on a simple mistake.
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

/// The session-selection window: a fixed-height scrollable checkbox list (so history length
/// changes the scroll region, never the window), a format radio group, and two toggles, with
/// Export/Cancel buttons. Runs as a classic blocking modal loop rather than a sheet, matching
/// every other Settings confirmation in this file.
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
        // The stack's actual height (sessions list + format + toggles + buttons) is shorter than
        // the placeholder frame above; shrink the window to fit instead of leaving whitespace.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 380, height: content.fittingSize.height))
    }

    /// Blocks until Export/Cancel/the window's close button is used; returns whether the user
    /// confirmed Export.
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

    /// Plain sibling `NSButton`s (not an `NSMatrix`) don't deselect each other automatically —
    /// enforce single-selection explicitly so picking a different format actually sticks.
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
