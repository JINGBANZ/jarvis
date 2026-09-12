import AppKit
import JarvisCore

/// A dropdown drawn inside the protected panel: native popup menus create separate,
/// unprotected windows. The scroll view keeps every mode reachable in a short overlay.
final class OverlayFormatPickerView: NSView {
    var onSelect: ((InterviewFormat?) -> Void)?
    var onDismiss: (() -> Void)?
    private let formats: [InterviewFormat?] = [nil] + InterviewFormat.availableCases.map { Optional($0) }
    private let scroll = NSScrollView()
    private let list = NSView()
    private var buttons: [NSButton] = []
    private let rowHeight: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        scroll.layer?.cornerRadius = 8
        scroll.documentView = list
        addSubview(scroll)
        for (index, format) in formats.enumerated() {
            let button = NSButton(title: format?.displayName ?? "None", target: self,
                                  action: #selector(selectMode(_:)))
            button.isBordered = false
            button.alignment = .left
            button.tag = index
            button.setAccessibilityLabel(button.title)
            buttons.append(button)
            list.addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("built in code; this project has no nibs") }

    func show(selected: InterviewFormat?) {
        for (index, button) in buttons.enumerated() {
            let name = formats[index]?.displayName ?? "None"
            button.attributedTitle = NSAttributedString(
                string: (formats[index] == selected ? "✓  " : "    ") + name,
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 13)])
            button.setAccessibilityValue(formats[index] == selected ? "Selected" : "")
        }
        isHidden = false
        layoutRows()
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        layoutRows()
    }

    private func layoutRows() {
        let width = max(0, min(230, bounds.width - 16))
        let height = CGFloat(buttons.count) * rowHeight
        let viewport = max(0, min(height, bounds.height - 8))
        scroll.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - viewport,
                              width: width, height: viewport)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 8, y: height - CGFloat(index + 1) * rowHeight,
                                  width: max(0, width - 16), height: rowHeight)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - viewport)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func selectMode(_ sender: NSButton) {
        guard formats.indices.contains(sender.tag) else { return }
        onSelect?(formats[sender.tag])
    }

    override func mouseDown(with event: NSEvent) { onDismiss?() }

    // Drive the same controls as a user, including the optional None entry.
    func choose(_ format: InterviewFormat?) {
        guard let index = formats.firstIndex(of: format) else { return }
        buttons[index].performClick(nil)
    }
}
