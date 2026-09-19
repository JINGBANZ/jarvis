import AppKit
import JarvisCore

@MainActor
public final class OverlayCaptionPanel: NSObject, OverlayRendering, OverlayCaptionApplying {
    private let panel: NSPanel
    private let label: NSTextField
    private struct Tip {
        var lines: [String]
        var seconds: [TimeInterval]
        var isError = false
        /// More lines may still close; `openLine` is the one being written.
        var isLive = false
        var openLine: String?
    }
    private var queue: [Tip] = []
    private var active: (tip: Tip, nextLine: Int)?
    /// A live tip whose next line has not closed holds the gap instead of ending.
    private var isWaitingForLine = false
    private var tickWorkItem: DispatchWorkItem?
    /// Settable so timing-sensitive tests can opt out.
    var interLineGapSeconds: TimeInterval = Config.overlayLineGapSeconds
    private var isPreviewing = false
    private var isEnabled = true
    private(set) var captureExclusionReassertCount = 0

    private enum Layout {
        static let width: CGFloat = 520
        static let minHeight: CGFloat = 80
        /// Must match the label's leading/trailing constraint constants.
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 16
        static let bottomMargin: CGFloat = 80
    }

    public override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.minHeight),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(Defaults.Overlay.Caption.opacity))
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.excludeFromScreenCapture()

        label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .white
        label.font = .systemFont(ofSize: CGFloat(Defaults.Overlay.Caption.fontSize), weight: .medium)
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
        resizeToFit()
    }

    /// Set `label.stringValue` first. Measures through the label's cell, not
    /// `NSString.boundingRect`, which ignores the cell's inset and under-measures large fonts.
    private func fittedHeight() -> CGFloat {
        let innerWidth = Layout.width - 2 * Layout.horizontalPadding
        let bounds = NSRect(x: 0, y: 0, width: innerWidth, height: .greatestFiniteMagnitude)
        let measured = label.cell?.cellSize(forBounds: bounds).height ?? 0
        return max(Layout.minHeight, ceil(measured) + 2 * Layout.verticalPadding)
    }

    /// Prefers `panel.screen` over `NSScreen.main`, which follows keyboard focus and would move a
    /// playing tip to another display.
    private func resizeToFit() {
        let h = fittedHeight()
        let w = Layout.width
        var origin = panel.frame.origin
        if let screen = panel.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            origin = NSPoint(x: f.midX - w / 2, y: f.minY + Layout.bottomMargin)
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true)
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        let cleaned = Self.cleaned(lines, perLineSeconds)
        guard !cleaned.isEmpty else { return }
        let tip = Tip(lines: cleaned.map(\.0), seconds: cleaned.map(\.1))
        Task { @MainActor in self.show(tip) }
    }

    /// Inline, unlike `render`, so finalizing a live tip is ordered after its progress updates.
    public func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                        detail: ReplyDetail?) -> ReplyDetail? {
        let cleaned = Self.cleaned(lines, perLineSeconds)
        let final = Tip(lines: cleaned.map(\.0), seconds: cleaned.map(\.1))
        if let (live, line) = active, live.isLive {
            var tip = live
            tip.lines = final.lines
            tip.seconds = final.seconds
            tip.isLive = false
            tip.openLine = nil
            active = (tip, line)
            if isWaitingForLine { advance() }
        } else if let index = queue.firstIndex(where: \.isLive) {
            if final.lines.isEmpty { queue.remove(at: index) } else { queue[index] = final }
        } else if !final.lines.isEmpty {
            show(final)
        }
        return nil
    }

    /// Line 1 shows as it is written; later lines join the tip as they close and play through
    /// `advance`. The live tip is the active one or waits in the queue behind an earlier tip.
    public func showReplyProgress(_ progress: BrainReplyProgress?, perLineSeconds: [TimeInterval]) {
        guard let progress else { return withdrawLiveTip() }
        let cleaned = Self.cleaned(progress.closedLines, perLineSeconds)
        let open = progress.openLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty || open?.isEmpty == false else { return }
        if let (live, line) = active, live.isLive {
            var tip = live
            tip.lines = cleaned.map(\.0)
            tip.seconds = cleaned.map(\.1)
            tip.openLine = open
            active = (tip, line)
            if isWaitingForLine { advance() }
        } else if let index = queue.firstIndex(where: \.isLive) {
            queue[index].lines = cleaned.map(\.0)
            queue[index].seconds = cleaned.map(\.1)
            queue[index].openLine = open
        } else {
            show(Tip(lines: cleaned.map(\.0), seconds: cleaned.map(\.1), isLive: true, openLine: open))
        }
    }

    private func withdrawLiveTip() {
        if let (tip, _) = active, tip.isLive {
            tickWorkItem?.cancel(); tickWorkItem = nil
            active = nil
            isWaitingForLine = false
            if queue.isEmpty { hide() } else { pumpQueue() }
        } else {
            queue.removeAll(where: \.isLive)
        }
    }

    private nonisolated static func cleaned(_ lines: [String], _ seconds: [TimeInterval]) -> [(String, TimeInterval)] {
        zip(lines, seconds)
            .map { ($0.0.trimmingCharacters(in: .whitespacesAndNewlines), $0.1) }
            .filter { !$0.0.isEmpty }
    }

    public func showError(_ message: String) {
        show(Tip(lines: [message], seconds: [4], isError: true))
    }

    private func show(_ tip: Tip) {
        guard isEnabled else { return }
        // An activation-policy flip can drop `sharingType`, so re-assert on every show.
        reassertCaptureExclusion()
        queue.append(tip)
        pumpQueue()
    }

    private func pumpQueue() {
        guard !isPreviewing, active == nil, !queue.isEmpty else { return }
        active = (queue.removeFirst(), 0)
        advance()
    }

    private func advance() {
        guard let (tip, line) = active else { return }
        isWaitingForLine = false
        let text: String
        if line < tip.lines.count {
            text = tip.lines[line]
            active = (tip, line + 1)
            scheduleTick(after: tip.seconds[line]) { $0.gapThenAdvance() }
        } else if tip.isLive {
            // The next line has not closed yet: line 1 shows as it is written, the rest wait blank.
            isWaitingForLine = true
            tickWorkItem?.cancel(); tickWorkItem = nil
            text = line == 0 ? tip.openLine ?? "" : ""
        } else {
            active = nil
            tickWorkItem = nil
            if queue.isEmpty { hide() } else { pumpQueue() }
            return
        }
        label.textColor = tip.isError ? .systemRed : .white
        label.stringValue = text
        resizeToFit()
        panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
    }

    private func gapThenAdvance() {
        label.stringValue = ""
        scheduleTick(after: interLineGapSeconds) { $0.advance() }
    }

    private func scheduleTick(after delay: TimeInterval, _ step: @escaping (OverlayCaptionPanel) -> Void) {
        tickWorkItem?.cancel()
        // asyncAfter on the main queue runs on the main thread, so assumeIsolated holds.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { step(self) }
        }
        tickWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hide() { panel.orderOut(nil) }

    /// Counted because macOS 26 normalizes `sharingType`, so reading it back can't tell a re-assert
    /// from the value set at init.
    private func reassertCaptureExclusion() {
        panel.excludeFromScreenCapture()
        captureExclusionReassertCount += 1
    }

    // MARK: - OverlayCaptionApplying

    private static let previewText = "Sample overlay text"

    public func setFontSize(_ points: Double) {
        label.font = .systemFont(ofSize: CGFloat(points), weight: .medium)
        if isPreviewing { resizeToFit() }
    }

    public func setBackgroundOpacity(_ opacity: Double) {
        panel.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity))
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled, !isPreviewing else { return }
        tickWorkItem?.cancel(); tickWorkItem = nil
        queue.removeAll()
        active = nil
        isWaitingForLine = false
        hide()
    }

    /// Turning the preview off hides the panel only if a preview is up, so closing Settings never
    /// tears down a real tip.
    public func showAppearancePreview(_ on: Bool) {
        if on {
            tickWorkItem?.cancel(); tickWorkItem = nil
            reassertCaptureExclusion()
            isPreviewing = true
            label.textColor = .white
            label.stringValue = Self.previewText
            resizeToFit()
            panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
        } else if isPreviewing {
            isPreviewing = false
            // `setEnabled(false)` deferred its cleanup while the preview was up; do it now.
            guard isEnabled else {
                tickWorkItem?.cancel(); tickWorkItem = nil
                queue.removeAll()
                active = nil
                isWaitingForLine = false
                hide()
                return
            }
            if active != nil {
                advance()
            } else if !queue.isEmpty {
                pumpQueue()
            } else {
                hide()
            }
        }
    }

    // MARK: - Test hooks (internal; reached via `@testable import JarvisOverlay`)

    var currentSharingType: NSWindow.SharingType { panel.sharingType }

    var currentFontPointSize: CGFloat { label.font?.pointSize ?? 0 }

    var currentBackgroundAlpha: CGFloat { panel.backgroundColor.alphaComponent }

    var currentText: String { label.stringValue }

    var isPanelVisible: Bool { panel.isVisible }

    var isShowingLiveTip: Bool { active?.tip.isLive == true }

    var currentPanelHeight: CGFloat { panel.frame.height }

    var currentPanelBottom: CGFloat { panel.frame.minY }
}
