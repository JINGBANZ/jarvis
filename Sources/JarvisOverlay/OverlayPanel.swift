import AppKit
import JarvisCore

/// A non-activating, always-on-top panel that shows coaching sentences one at a time and is
/// excluded from screen capture — both so Jarvis's own brain never sees its output and so the
/// overlay stays invisible in anyone else's screen share or recording (Zoom/Meet/Teams/QuickTime).
/// See `init` and wiki/overlay-invisibility.md.
@MainActor
public final class OverlayPanel: NSObject, OverlayRendering, OverlayAppearanceApplying {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?
    /// Test hook (internal): counts how many times `show()` has re-asserted capture exclusion.
    private(set) var captureExclusionReassertCount = 0

    public override init() {
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
        // Exclude from ALL screen capture. This one flag does double duty: it keeps the overlay out
        // of Jarvis's own `capture_screen` shots (so the brain never reads its own output) AND hides
        // it from anyone else's screen share or recording. It is the same OS mechanism every
        // comparable tool uses (Electron's setContentProtection / Tauri's contentProtected both map
        // to it); there is no other public API. Verified on macOS 26.5 across the screencapture CLI,
        // SCScreenshotManager, and a live SCStream. Re-asserted in show(). See
        // wiki/overlay-invisibility.md.
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
    public nonisolated func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval) {
        let sentences = splitIntoSentences(text, maxSentences: maxSentences)
        guard !sentences.isEmpty else { return }
        Task { @MainActor in self.show(sentences, each: perSentenceSeconds) }
    }

    private func show(_ sentences: [String], each: TimeInterval) {
        // Re-assert capture exclusion on every display: an NSApp activation-policy flip (e.g. the
        // API-key dialog in MenuBarController.setKey) can make WindowServer drop sharingType on some
        // macOS versions/configs. Cheap insurance against a silent, high-impact regression — the
        // overlay becoming visible to a screen share with no signal. See wiki/overlay-invisibility.md.
        panel.sharingType = .none
        captureExclusionReassertCount += 1
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

    // MARK: - OverlayAppearanceApplying

    /// Live preview sample shown while the Settings window is open.
    private static let previewText = "Sample overlay text"

    public func setFontSize(_ points: Double) {
        label.font = .systemFont(ofSize: CGFloat(points), weight: .medium)
    }

    public func setBackgroundOpacity(_ opacity: Double) {
        panel.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity))
    }

    /// Show a sample tip (on) or clear it (off). Cancels any pending auto-hide so a live coaching
    /// tip doesn't yank the preview away mid-adjust, and re-asserts capture exclusion (same
    /// defense-in-depth as `show()`; an activation-policy flip can drop `sharingType`).
    public func showAppearancePreview(_ on: Bool) {
        if on {
            hideWorkItem?.cancel()
            panel.sharingType = .none
            label.stringValue = Self.previewText
            panel.orderFrontRegardless()
        } else {
            hide()
        }
    }

    // MARK: - Test hooks (internal; reached via `@testable import JarvisOverlay`)

    /// The panel's current capture-sharing type. `.none` means excluded from screen capture.
    var currentSharingType: NSWindow.SharingType { panel.sharingType }

    /// The label's current font point size.
    var currentFontPointSize: CGFloat { label.font?.pointSize ?? 0 }

    /// The panel background's current alpha (the opacity the user picked).
    var currentBackgroundAlpha: CGFloat { panel.backgroundColor.alphaComponent }
}
