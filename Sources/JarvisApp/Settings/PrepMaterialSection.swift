import AppKit
import JarvisCore
import UniformTypeIdentifiers

/// Settings panel for the local files/folders of prepared interview notes the coach can reference.
///
/// Jarvis stores only these paths, never a copy of their contents, and reads them fresh when needed —
/// so removing a source here only forgets it; the underlying file is untouched. Nothing here is ever
/// uploaded: the list is persisted the same way every other setting is, in this macOS account's own
/// UserDefaults domain.
@MainActor
final class PrepMaterialSection: NSObject, SettingsSection {
    let title = "Prep Material"
    let fillsTab = true

    private static let rowHeight: CGFloat = 56
    private static let addRowHeight: CGFloat = 42
    private static let emptyStateHeight: CGFloat = 44

    private let preferences: PrepMaterialPreferences
    private let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 712, height: 200))
    private let addButton = NSButton(title: "＋ Add Files or Folders…", target: nil, action: nil)
    private var rows: [SettingsRowView] = []
    private var rowsBySourceID: [UUID: SettingsRowView] = [:]
    private var emptyLabel: NSTextField?
    /// Guards a background existence check against a stale result landing after a newer `render()`
    /// (a fast add/remove, or leaving and returning to the tab) already rebuilt the row list.
    private var renderGeneration = 0

    init(preferences: PrepMaterialPreferences) {
        self.preferences = preferences
    }

    func makeView() -> NSView {
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 712, height: 432))

        let scrollView = SettingsScrollView(frame: NSRect(x: 0, y: 0, width: 712, height: 350))
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        card.autoresizingMask = [.width]
        card.setHeader(title: "Prep material", detail: "Local only — never uploaded")
        addButton.target = self
        addButton.action = #selector(addSource)
        addButton.bezelStyle = .rounded
        addButton.setAccessibilityLabel("Add prep material")
        card.contentView?.addSubview(addButton)
        card.onLayout = { [weak self] in self?.layoutRows() }
        scrollView.documentView = card

        render()

        let callout = makeCallout()
        callout.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(scrollView)
        body.addSubview(callout)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            callout.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: SettingsStyle.sectionSpacing),
            callout.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            callout.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            callout.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            callout.heightAnchor.constraint(equalToConstant: 68),
        ])

        return SettingsPageView(
            title: "Prep Material",
            summary: "Point Jarvis at notes you've already prepared, so it can draw on them live.",
            bodyView: body)
    }

    func didBecomeActive() {
        // A source's file may have moved or been deleted since the tab was last open.
        render()
    }

    private func makeCallout() -> NSBox {
        let callout = NSBox()
        callout.boxType = .custom
        callout.borderWidth = 1
        callout.cornerRadius = 10
        callout.borderColor = NSColor.systemBlue.withAlphaComponent(0.18)
        callout.fillColor = NSColor.systemBlue.withAlphaComponent(0.07)
        callout.contentViewMargins = .zero

        guard let content = callout.contentView else { return callout }
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemBlue
        content.addSubview(icon)

        let note = NSTextField(wrappingLabelWithString:
            "Jarvis only reads these files and folders — it never copies, edits, or uploads them. "
            + "Removing a source here does not delete anything on disk.")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            note.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            note.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        return callout
    }

    private var preferredHeight: CGFloat {
        let listHeight = rows.isEmpty
            ? Self.emptyStateHeight
            : CGFloat(rows.count) * Self.rowHeight
        return SettingsStyle.cardHeaderHeight + listHeight + Self.addRowHeight
    }

    private func render() {
        renderGeneration += 1
        let generation = renderGeneration

        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        rowsBySourceID.removeAll()
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil

        let sources = preferences.sources
        if sources.isEmpty {
            let label = NSTextField(labelWithString: "No prep material added yet.")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            card.contentView?.addSubview(label)
            emptyLabel = label
        } else {
            for source in sources {
                let removeButton = ClosureButton(title: "×") { [weak self] in
                    self?.removeSource(id: source.id)
                }
                removeButton.bezelStyle = .rounded
                removeButton.controlSize = .small
                removeButton.setAccessibilityLabel("Remove \(source.displayName)")

                let row = SettingsRowView(
                    title: source.displayName,
                    detail: source.path,
                    controlView: removeButton,
                    controlSize: NSSize(width: 30, height: 30),
                    preferredHeight: Self.rowHeight)
                card.contentView?.addSubview(row)
                rows.append(row)
                rowsBySourceID[source.id] = row
            }
        }

        card.frame.size.height = preferredHeight
        layoutRows()

        // Existence is a stat() per source, which can block on an unresponsive network volume or a
        // sleeping external disk — never do it on the main thread. Rows show their plain path until
        // this resolves, then a still-current render applies the ⚠️ warning to whichever are missing.
        guard !sources.isEmpty else { return }
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
            rowsBySourceID[source.id]?.setDetail("⚠️ Not found — \(source.path)")
        }
    }

    private func layoutRows() {
        let width = card.bounds.width
        var nextTop = preferredHeight - SettingsStyle.cardHeaderHeight
        for row in rows {
            nextTop -= Self.rowHeight
            row.frame = NSRect(x: 0, y: nextTop, width: width, height: Self.rowHeight)
        }
        if let emptyLabel {
            nextTop -= Self.emptyStateHeight
            emptyLabel.frame = NSRect(
                x: 16, y: nextTop, width: max(200, width - 32), height: Self.emptyStateHeight)
        }
        addButton.frame = NSRect(x: 16, y: 5, width: 220, height: 32)
    }

    /// Formats the indexing slice will actually be able to read: plain text/Markdown directly, PDF
    /// via PDFKit, and Word documents via the stock `textutil` CLI. `UTType(filenameExtension:)`
    /// synthesizes a type for ".md"/".docx", which have no dedicated system UTI, so the filter still
    /// matches them by extension. Folders are unfiltered — their contents are filtered by the same
    /// list at indexing time instead.
    private static let allowedContentTypes: [UTType] = [
        .plainText, .pdf, UTType(filenameExtension: "md"), UTType(filenameExtension: "docx"),
    ].compactMap { $0 }

    @objc private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose interview notes Jarvis can reference while coaching. Files stay in place."
        guard panel.runModal() == .OK else { return } // ghost-mode-allowed: explicit user action in Settings

        let fm = FileManager.default
        var newSources: [PrepMaterialSource] = []
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            newSources.append(PrepMaterialSource(path: url.path, isDirectory: isDirectory.boolValue))
        }
        preferences.add(newSources)
        render()
    }

    private func removeSource(id: UUID) {
        preferences.remove(id: id)
        render()
    }
}
