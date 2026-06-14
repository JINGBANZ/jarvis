import AppKit
import JarvisCore

/// A non-activating, always-on-top panel that shows coaching sentences one at a time and is
/// excluded from screen capture (so the model never sees Jarvis's own output).
@MainActor
final class OverlayPanel: NSObject, OverlayRendering {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Exclude from screen capture so capture_screen never sees the overlay.
        panel.sharingType = .none

        label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false

        let content = panel.contentView!
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        super.init()
        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let w: CGFloat = 520, h: CGFloat = 80
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 80, width: w, height: h), display: true)
    }

    /// OverlayRendering witness — nonisolated so it satisfies the protocol; hops to the main actor.
    nonisolated func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval) {
        let sentences = splitIntoSentences(text, maxSentences: maxSentences)
        guard !sentences.isEmpty else { return }
        Task { @MainActor in self.show(sentences, each: perSentenceSeconds) }
    }

    private func show(_ sentences: [String], each: TimeInterval) {
        hideWorkItem?.cancel()
        var idx = 0
        func next() {
            guard idx < sentences.count else { hide(); return }
            label.stringValue = sentences[idx]
            panel.orderFrontRegardless()
            idx += 1
            let work = DispatchWorkItem { MainActor.assumeIsolated { next() } }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + each, execute: work)
        }
        next()
    }

    private func hide() { panel.orderOut(nil) }
}
