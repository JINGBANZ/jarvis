import AppKit
import JarvisCore

/// A non-activating, always-on-top panel that shows coaching tips one line at a time and is
/// excluded from screen capture — both so Jarvis's own brain never sees its output and so the
/// overlay stays invisible in anyone else's screen share or recording (Zoom/Meet/Teams/QuickTime).
/// A newer tip never interrupts one still on screen; it queues and plays after, so no hint is
/// dropped. See `init` and wiki/overlay-invisibility.md.
@MainActor
public final class OverlayPanel: NSObject, OverlayRendering, OverlayAppearanceApplying {
    private let panel: NSPanel
    private let label: NSTextField
    /// One coaching tip: its lines and how long each one is shown (aligned arrays; `seconds[i]`
    /// is the display time for `lines[i]`, scaled to that line's length — see `OverlayTiming`).
    private struct Tip { let lines: [String]; let seconds: [TimeInterval] }
    /// Tips waiting their turn. A tip the user may still be reading is never cut off by a newer one —
    /// arrivals queue here and play in order once the current tip finishes.
    private var queue: [Tip] = []
    /// The tip currently on screen and the index of the NEXT line to show. Held as instance state (not
    /// inside the advance closure) so a Settings preview can pause it and later resume the exact line.
    private var active: (tip: Tip, nextLine: Int)?
    /// The pending line-advance work, retained so the Settings live preview can cancel (pause) it.
    private var tickWorkItem: DispatchWorkItem?
    /// Brief blank inserted between consecutive lines (and before the next queued tip) so a glancing
    /// eye registers that the text changed — see Config.overlayLineGapSeconds and wiki/overlay-timing.md.
    /// Settable so timing-sensitive tests can opt out.
    var interLineGapSeconds: TimeInterval = Config.overlayLineGapSeconds
    /// Whether the Settings live preview currently owns the panel. While true, an active tip is paused
    /// and newly-arriving tips wait in the queue; they resume/play when the preview closes.
    private var isPreviewing = false
    /// Test hook (internal): counts how many times `show()` has re-asserted capture exclusion.
    private(set) var captureExclusionReassertCount = 0

    public override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(Config.overlayOpacityDefault))
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
        label.font = .systemFont(ofSize: CGFloat(Config.overlayFontSizeDefault), weight: .medium)
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
    /// The brain already split the tip into lines; we just trim and drop any empties (carrying each
    /// line's display time along with it so the two stay aligned) before showing.
    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        let cleaned = zip(lines, perLineSeconds)
            .map { ($0.0.trimmingCharacters(in: .whitespacesAndNewlines), $0.1) }
            .filter { !$0.0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let tip = Tip(lines: cleaned.map(\.0), seconds: cleaned.map(\.1))
        Task { @MainActor in self.show(tip) }
    }

    private func show(_ tip: Tip) {
        // Re-assert capture exclusion on every display: an NSApp activation-policy flip (e.g. opening
        // the Settings window in SettingsWindow.show) can make WindowServer drop sharingType on some
        // macOS versions/configs. Cheap insurance against a silent, high-impact regression — the
        // overlay becoming visible to a screen share with no signal. See wiki/overlay-invisibility.md.
        reassertCaptureExclusion()
        // Queue rather than interrupt: a tip the user is still reading must not vanish because a newer
        // one arrived. Tips play in arrival order and none are dropped.
        queue.append(tip)
        pumpQueue()
    }

    /// Begin the next queued tip if the panel is free. A no-op while a tip is already on screen (the
    /// new one waits its turn) or while the Settings preview owns the panel (queued tips resume when
    /// the preview closes) — so a tip is never interrupted or dropped.
    private func pumpQueue() {
        guard !isPreviewing, active == nil, !queue.isEmpty else { return }
        active = (queue.removeFirst(), 0)
        advance()
    }

    /// Show the active tip's current line, then after its display time blank the panel for the
    /// inter-line gap before advancing. When the tip's lines are exhausted, move on to the next queued
    /// tip, or hide the panel if nothing is waiting. Resumable: it reads the line index from `active`,
    /// so a preview can pause it (cancel the tick) and resume exactly here.
    private func advance() {
        guard let (tip, line) = active else { return }
        guard line < tip.lines.count else {
            active = nil
            tickWorkItem = nil   // tip done: drop the fired work item (no lingering self-capture)
            if queue.isEmpty { hide() } else { pumpQueue() }
            return
        }
        label.stringValue = tip.lines[line]
        panel.orderFrontRegardless()
        active = (tip, line + 1)
        scheduleTick(after: tip.seconds[line]) { $0.gapThenAdvance() }
    }

    /// Blank the on-screen text for the inter-line gap, then advance to the next line/tip. The brief
    /// blank is what makes a glancing eye notice the text changed (the captioning minimum-gap idea).
    private func gapThenAdvance() {
        label.stringValue = ""
        scheduleTick(after: interLineGapSeconds) { $0.advance() }
    }

    /// Schedule the next playback step on the main queue. The work item captures `self` weakly so the
    /// self -> tickWorkItem -> closure -> self cycle can't form; `step` takes the panel non-capturing.
    /// Cancels any prior pending tick first, so the "at most one pending tick" invariant is enforced
    /// here rather than relying on every caller to have fired/cancelled the previous one.
    private func scheduleTick(after delay: TimeInterval, _ step: @escaping (OverlayPanel) -> Void) {
        tickWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { step(self) }
        }
        tickWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hide() { panel.orderOut(nil) }

    /// Re-apply screen-capture exclusion and count it, so tests can prove the re-assert ran (on
    /// macOS 26 the OS normalizes `sharingType`, so asserting `== .none` alone can't tell a real
    /// re-assert from the value set at init). See wiki/overlay-invisibility.md.
    private func reassertCaptureExclusion() {
        panel.sharingType = .none
        captureExclusionReassertCount += 1
    }

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
    /// defense-in-depth as `show()`; an activation-policy flip can drop `sharingType`). Turning the
    /// preview off only hides the panel if a preview is actually up — so closing Settings never
    /// tears down a genuine coaching tip that `show()` put on screen in the meantime.
    public func showAppearancePreview(_ on: Bool) {
        if on {
            tickWorkItem?.cancel(); tickWorkItem = nil   // pause the active tip; `active` keeps its line index for resume
            reassertCaptureExclusion()
            isPreviewing = true
            label.stringValue = Self.previewText
            panel.orderFrontRegardless()
        } else if isPreviewing {
            isPreviewing = false
            if active != nil {
                advance()        // resume the paused tip from the exact line it stopped on
            } else if !queue.isEmpty {
                pumpQueue()      // a tip arrived while previewing — play it now
            } else {
                hide()           // nothing to show; clear the sample text
            }
        }
    }

    // MARK: - Test hooks (internal; reached via `@testable import JarvisOverlay`)

    /// The panel's current capture-sharing type. `.none` means excluded from screen capture.
    var currentSharingType: NSWindow.SharingType { panel.sharingType }

    /// The label's current font point size.
    var currentFontPointSize: CGFloat { label.font?.pointSize ?? 0 }

    /// The panel background's current alpha (the opacity the user picked).
    var currentBackgroundAlpha: CGFloat { panel.backgroundColor.alphaComponent }

    /// The line currently displayed on the overlay — lets tests assert queue/ordering behavior.
    var currentText: String { label.stringValue }

    /// Whether the panel is on screen — lets tests assert the drain-then-hide transition.
    var isPanelVisible: Bool { panel.isVisible }
}
