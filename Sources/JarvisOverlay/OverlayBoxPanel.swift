import AppKit
import JarvisCore

/// The Overlay Box: a persistent, borderless box that logs every coaching response in full — the
/// running history of what the caption flashed one line at a time, each line timestamped. It conforms
/// to the same `OverlayRendering` seam as `OverlayCaptionPanel`, so `CoachDriver` feeds both through
/// one `render` call (fanned out by `BroadcastOverlay`); this panel simply appends each tip instead of
/// timing it out.
///
/// Like the caption it is excluded from all screen capture (so it stays invisible in a screen share
/// and the brain never reads it back) and carries no window-server chrome. Unlike the caption it
/// accepts mouse events: drag anywhere to move it, scroll to read the backlog, drag its edges to
/// resize it. Its own chrome is `OverlayBoxHeaderView` across the top — collapse, the name, clear —
/// sized from the box by `OverlayBoxChrome` rather than fixed.
///
/// It is a session surface: it appears on Start (cleared, for the new conversation) and disappears on
/// Stop, so a stopped Jarvis leaves nothing on the desktop. The Settings toggle is the master switch
/// over that — switched off, the box never appears at all.
///
/// The panel itself never touches UserDefaults: it reports a finished resize through
/// `onSizeChanged` and takes the restored size as an `init` parameter, leaving persistence to
/// `OverlayAppearance` — the same split the font-size and opacity settings already use.
@MainActor
public final class OverlayBoxPanel: NSObject, OverlayRendering, OverlayBoxApplying {
    private let panel: NSPanel
    /// The layer-backed, opaque rounded fill behind the text — its alpha is the box's opacity.
    private let box: ResizeReportingView
    private let textView: NSTextView
    private let codeView = CodeSnippetView(frame: .zero)
    private var codeSnippet: CodeSnippet?
    private var codeEnabled = Defaults.Code.enabled
    private static let sampleCode = CodeSnippet(language: "swift", placement: "At the start of solve",
        code: "guard !items.isEmpty else { return nil }\nlet first = items[0]")
    /// The chrome strip across the top: collapse, the name, clear.
    private let header: OverlayBoxHeaderView
    /// The scrolling log under the header. Held so the header's height can be taken off it on every
    /// resize, and so collapsing can put it away.
    private let scroll: NSScrollView
    /// Draws the box's resize affordance along whichever edge the pointer is over, and owns the drag
    /// on those edges so the region that lights is the region that resizes.
    private let resizeAffordance: OverlayBoxResizeAffordanceView
    /// Whether the box is rolled up to its header. A gesture for the current conversation rather than
    /// a preference, so nothing persists it and Start opens the box again.
    private(set) var isCollapsed = false
    /// The height the box has when it is not rolled up: the size the user dragged to, and the one the
    /// header's proportions are taken from at every moment, collapsed or not.
    private var expandedContentHeight: CGFloat
    /// The smallest height a drag may reach, and the one the collapsed box restores on expand.
    private static let heightFloor = CGFloat(Defaults.Overlay.Box.heightRange.lowerBound)
    /// The header's geometry for the box's expanded height, which is what it keeps while collapsed.
    private var chrome: OverlayBoxChrome { OverlayBoxChrome(contentHeight: expandedContentHeight) }
    /// White level of the box fill; the opacity setting only varies the alpha, keeping this constant.
    private static let boxWhite: CGFloat = 0.10
    /// Point size of the response text; the timestamp is rendered a couple points smaller. Driven by
    /// the Settings slider via `setFontSize`.
    private var fontSize: CGFloat = CGFloat(Defaults.Overlay.Box.fontSize)
    /// What the box is currently showing.
    ///
    /// The Settings preview swaps the *source* rather than the panel, so everything derived from what
    /// is on screen is computed from this in one place (`renderDisplay`). As a boolean consulted at
    /// each call site it was forgotten three times: by the clear button, by collapse, and by the
    /// header's clear action, which quietly wiped the session's log.
    private enum Display { case log, sample }
    private var display: Display = .log
    /// Whether the Settings Overlay tab wants the sample standing in. Recorded rather than obeyed,
    /// exactly like `isEnabled`: Settings cannot see whether a session is running, so it asks once
    /// when its tab opens and the panel resolves the request whenever either side changes. Discarding
    /// the request instead left the sliders with nothing on screen to act on after a Stop taken
    /// without leaving the tab.
    private var isPreviewRequested = false
    /// Whether the box was rolled up when the Settings preview opened, so closing it can restore that.
    /// It cannot straddle a session: Start takes the sample down, which spends it.
    private var wasCollapsedBeforePreview = false
    /// The Settings toggle: the user's master switch. Off means the box never appears.
    private var isEnabled = false
    /// Whether a coaching session is running. Set by the app on Start and Stop.
    private var isSessionLive = false
    /// Reports the box's new content size once a resize drag finishes.
    public var onSizeChanged: ((Double, Double) -> Void)?
    /// Stand-in responses shown during the Settings preview.
    private static let sampleEntries: [(stamp: String, text: String, explanation: String?, diagram: DiagramHint?, isError: Bool)] = [
        ("10:30:00", "Ask about the time complexity of that loop.", nil, nil, false),
        ("10:30:08", "Check the empty list before reading its first item.",
         "An empty list has no first item. Handle that case before indexing into it, then continue with the normal path.", nil, false),
    ]
    /// Each spoken tip with the time it arrived, newest last. Held as structured entries (not the
    /// rendered string) so `clear()` and the test hooks don't have to parse the text back out.
    private var diagramsEnabled = Defaults.Overlay.Box.diagramsEnabled
    private var latestEntryStart = 0
    private var entries: [(stamp: String, text: String, explanation: String?, diagram: DiagramHint?, isError: Bool)] = []
    /// Test hook (internal): counts how many times the panel has re-asserted capture exclusion.
    private(set) var captureExclusionReassertCount = 0

    /// `HH:mm:ss`, pinned to a fixed locale so the prefix is stable regardless of the user's locale.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// - Parameter contentSize: the size the user last dragged the box to. Taken at construction so
    ///   the panel is built at its final size and centered once, rather than being resized after the
    ///   fact — `setContentSize` pins the top-left, so a later resize would leave the box off-centre,
    ///   and a second `center()` is an AppKit call this panel does not need. This panel queries no
    ///   screen at all: `NSScreen` access in `init` blocks AppKit on a host with no GUI session and
    ///   hangs every main-actor test.
    public init(contentSize: NSSize = NSSize(
        width: Defaults.Overlay.Box.width,
        height: Defaults.Overlay.Box.height)
    ) {
        // `.resizable` lets the user drag the borderless box's edges to resize it (no visible chrome,
        // but the window server still provides edge resizing on a resizable window). `minSize` keeps it
        // from being shrunk to nothing.
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered, defer: false)
        // The drag floor is the persisted floor, so a dragged size always survives a round trip.
        panel.minSize = NSSize(
            width: Defaults.Overlay.Box.widthRange.lowerBound,
            height: Self.heightFloor)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Borderless + opaque rounded box: the window itself is transparent so the corners can round;
        // the opaque fill is drawn by the layer-backed content view below.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // drag anywhere on the box to move it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = ResizeReportingView(frame: panel.contentRect(forFrameRect: panel.frame))
        box.wantsLayer = true
        // From the registry, like `fontSize` above: a literal here would be a second default that
        // silently disagrees with `Defaults.Overlay.Box.opacity` for any caller but `AppDelegate`.
        box.layer?.backgroundColor = NSColor(
            white: Self.boxWhite,
            alpha: CGFloat(Defaults.Overlay.Box.opacity)).cgColor
        box.layer?.cornerRadius = OverlayBoxChrome.cornerRadius
        box.layer?.masksToBounds = true
        self.box = box

        let scroll = NSScrollView(frame: box.bounds)
        scroll.hasVerticalScroller = true
        // Keep the history scrollable without reserving a persistent legacy-style gutter. AppKit's
        // preferred style can differ by linked SDK and input device, so this must not be implicit.
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false        // let the opaque box show through
        scroll.borderType = .noBorder

        // Drag-to-move over the text area too (a plain NSTextView would swallow the drag). Non-editable,
        // non-selectable: this is a read-only readout, so clicks should move the window, not select.
        let tv = MovableTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        let unbounded = CGFloat.greatestFiniteMagnitude
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: unbounded, height: unbounded)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: unbounded)
        scroll.documentView = tv
        textView = tv
        self.scroll = scroll

        let header = OverlayBoxHeaderView(chrome: OverlayBoxChrome(contentHeight: contentSize.height))
        self.header = header
        expandedContentHeight = contentSize.height
        let affordance = OverlayBoxResizeAffordanceView(frame: box.bounds)
        resizeAffordance = affordance

        box.addSubview(scroll)
        box.addSubview(codeView)
        codeView.isHidden = true
        box.addSubview(header)
        box.addSubview(affordance)   // topmost, so its tracking area sees the whole box
        panel.contentView = box
        super.init()
        codeView.onDismiss = { [weak self] in
            guard let self else { return }
            if self.display == .log { self.codeSnippet = nil }
            self.codeView.show(nil, fontSize: self.fontSize, enabled: self.codeEnabled && !self.isCollapsed)
            self.layoutCode()
        }
        header.collapseButton.target = self
        header.collapseButton.action = #selector(toggleCollapsed)
        header.clearButton.target = self
        header.clearButton.action = #selector(clearLog)
        box.onEndLiveResize = { [weak self] in self?.reportContentSize() }
        box.onFrameSizeChanged = { [weak self] in self?.layoutContent() }
        // The affordance drives edge drags itself, so AppKit's live-resize hook never fires for them.
        affordance.onResizeFinished = { [weak self] in self?.reportContentSize() }
        layoutContent()
        // Centered on screen initially; the user can drag it anywhere from there (the frame persists
        // across menu toggles, since hide() only orders it out).
        panel.center()
        panel.excludeFromScreenCapture()
    }

    /// Place the header and the log for the box's current size, and resize the header to match.
    /// Driven from the content view's `setFrameSize`, so it settles synchronously on every frame of a
    /// resize drag rather than waiting on an AppKit layout pass an offscreen panel never runs.
    private func layoutContent() {
        let bounds = box.bounds
        if !isCollapsed { expandedContentHeight = bounds.height }
        header.apply(chrome)
        header.frame = NSRect(x: 0, y: bounds.height - chrome.height,
                              width: bounds.width, height: chrome.height)
        scroll.frame = NSRect(x: 0, y: 0,
                              width: bounds.width, height: max(0, bounds.height - chrome.height))
        resizeAffordance.frame = bounds
        // After the scroll view has its new width, so a diagram hint is rasterized to fit it.
        renderDisplay()
    }

    // MARK: - Header actions

    @objc private func toggleCollapsed() { setCollapsed(!isCollapsed) }

    /// `clear()` is the model operation Start uses, and it wipes the log whatever is on screen. This
    /// is the user's gesture, so it declines while the display is not the log: the button is hidden
    /// then anyway, and clearing behind a sample would destroy the history with nothing on screen
    /// changing to show it had happened.
    @objc private func clearLog() {
        guard display == .log else { return }
        clear()
    }

    /// Roll the box down to its header and back. Both the width and the height the user dragged to
    /// survive the round trip, so collapsing costs them nothing.
    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        header.setCollapsed(collapsed)
        resizeAffordance.allowsVerticalResize = !collapsed
        scroll.isHidden = collapsed

        let collapsedHeight = chrome.height
        // Floor and ceiling meet while collapsed: with only the header on screen, a vertical drag has
        // nothing to stretch. Both are set before the resize so neither clamps it.
        panel.minSize = NSSize(
            width: panel.minSize.width,
            height: collapsed ? collapsedHeight : Self.heightFloor)
        panel.maxSize = NSSize(width: panel.maxSize.width,
                               height: collapsed ? collapsedHeight : .greatestFiniteMagnitude)

        // Anchor the top edge explicitly rather than leaning on `setContentSize`, which pins the
        // top-left only while the window is on screen and the bottom-left once it is ordered out.
        // Stop orders the box out, so a box collapsed before Stop would expand upward on the next
        // Start and come back a screenful from where the user left it.
        let frame = panel.frame          // borderless: the frame is the content rect
        let height = collapsed ? collapsedHeight : expandedContentHeight
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height,
                              width: frame.width, height: height),
                       display: true)
    }

    // MARK: - OverlayRendering

    /// Append the spoken tip (its lines joined into one paragraph, timestamped) to the log. Nonisolated
    /// to satisfy the protocol; hops to the main actor. Empty/whitespace-only lines are dropped,
    /// matching the overlay, so a no-text tip never adds a blank entry.
    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        render(lines, perLineSeconds: perLineSeconds, diagram: nil)
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?) {
        render(lines, perLineSeconds: perLineSeconds, diagram: diagram, explanation: nil)
    }

    public nonisolated func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?, explanation: String?) {
        let summary = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !summary.isEmpty else { return }
        let detail = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { @MainActor in
            self.append(summary, explanation: detail.isEmpty ? nil : detail, diagram: diagram)
        }
    }

    /// Fixed error copy stays in the existing nonactivating, capture-excluded history panel.
    public func showError(_ message: String) {
        append(message, explanation: nil, diagram: nil, isError: true)
    }

    public func deliverCodeSnippet(_ snippet: CodeSnippet?) -> CodeSnippet? {
        codeSnippet = acceptsDetail && codeEnabled ? snippet : nil
        refreshCode()
        if panel.isVisible { reassertCaptureExclusion() }
        return codeSnippet
    }

    public func setCodeEnabled(_ enabled: Bool) {
        codeEnabled = enabled
        if !enabled { codeSnippet = nil }
        refreshCode()
    }

    private func refreshCode() {
        codeView.show(codeEnabled ? (display == .sample ? Self.sampleCode : codeSnippet) : nil,
                      fontSize: fontSize, enabled: codeEnabled && !isCollapsed)
        layoutCode()
    }

    private func layoutCode() {
        let available = max(0, box.bounds.height - chrome.height)
        let preferred = min(box.bounds.height * 0.45,
            76 + CGFloat(codeView.snippet?.code.components(separatedBy: "\n").count ?? 0) * (fontSize + 4))
        // Preserve the header and one history line even at the minimum expanded size.
        let height = codeView.isHidden ? 0 : min(max(0, available - 44), max(96, preferred))
        codeView.frame = NSRect(x: 0, y: 0, width: box.bounds.width, height: height)
        scroll.frame = NSRect(x: 0, y: height, width: box.bounds.width, height: max(0, available - height))
    }

    public func deliver(_ lines: [String], perLineSeconds: [TimeInterval],
                        diagram: DiagramHint?, explanation: String?) -> String? {
        let summary = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !summary.isEmpty else { return nil }
        let detail = acceptsDetail ? explanation : nil
        append(summary, explanation: detail, diagram: diagram)
        return detail
    }

    private func append(_ text: String, explanation: String?, diagram: DiagramHint?, isError: Bool = false) {
        entries.append((stamp: timeFormatter.string(from: Date()), text: text, explanation: explanation, diagram: diagram, isError: isError))
        // No preview can be running: one only opens while stopped, and Start ends it.
        // Re-assert capture exclusion on every render that reaches the screen — same defense-in-depth as
        // OverlayCaptionPanel.show, since this box can be visible (full of responses) while Settings flips the
        // activation policy and WindowServer drops `sharingType` on vulnerable macOS builds.
        if panel.isVisible { reassertCaptureExclusion() }
        renderDisplay()
        if explanation != nil || (diagram != nil && diagramsEnabled) {
            // A tall diagram may exceed the viewport. Start at its hint, not its last row.
            if let layout = textView.layoutManager, let container = textView.textContainer {
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(
                    forCharacterRange: NSRange(location: latestEntryStart, length: 1), actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                textView.scroll(NSPoint(x: 0, y: rect.minY + textView.textContainerInset.height))
            }
        } else {
            textView.scrollToEndOfDocument(nil)   // keep the newest response in view
        }
    }

    /// Build the current display, including labeled explanations and optional diagrams.
    private func renderDisplay() {
        let items = display == .sample ? Self.sampleEntries : entries
        let result = NSMutableAttributedString()
        let stampAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1, alpha: 0.5),
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(8, fontSize - 2), weight: .regular),
        ]
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize),
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        let explanationLabelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1, alpha: 0.75),
            .font: NSFont.systemFont(ofSize: max(8, fontSize - 2), weight: .medium),
        ]
        for (i, entry) in items.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n\n")) }
            latestEntryStart = result.length
            result.append(NSAttributedString(string: "\(entry.stamp)  ", attributes: stampAttrs))
            var entryAttrs = hintAttrs
            if entry.isError { entryAttrs[.foregroundColor] = NSColor.systemRed }
            result.append(NSAttributedString(string: entry.text, attributes: entryAttrs))
            if let explanation = entry.explanation {
                result.append(NSAttributedString(string: "\n\nExplanation\n", attributes: explanationLabelAttrs))
                result.append(NSAttributedString(string: explanation, attributes: textAttrs))
            }
            if diagramsEnabled, let diagram = entry.diagram {
                result.append(NSAttributedString(string: "\n"))
                let attachment = NSTextAttachment()
                let padding = 2 * (textView.textContainer?.lineFragmentPadding ?? 0)
                attachment.image = DiagramHintImage.render(diagram, fitting: NSSize(
                    width: max(1, box.bounds.width - 2 * textView.textContainerInset.width - padding),
                    // Reserve space for the written hint; the diagram never dominates a short box.
                    height: max(1, box.bounds.height * 0.6)))
                result.append(NSAttributedString(attachment: attachment))
            }
        }
        textView.textStorage?.setAttributedString(result)
        // The sample is not the user's log, so it offers nothing to erase: the clear button stays away
        // rather than sitting there as a control that does nothing.
        header.setHasContent(display == .log && !entries.isEmpty)
        refreshCode()
    }

    // MARK: - Visibility (the Settings toggle, gated on a live session)

    /// Wipe the log. Called on each fresh Start so the box shows only the current conversation,
    /// matching how the session rotates.
    public func clear() {
        codeSnippet = nil
        entries.removeAll()
        renderDisplay()
    }

    /// Whether the box belongs on screen: switched on *and* a session running. Kept distinct from
    /// `panel.isVisible` because the Settings preview can show the box without either being true; the
    /// preview restores to this on close, so the box can never disagree with the setting or outlive Stop.
    public var acceptsDetail: Bool { shouldBeVisible && !isCollapsed }

    private var shouldBeVisible: Bool { isEnabled && isSessionLive }

    /// Bring the panel to whatever `shouldBeVisible` now says. One place owns the rule, so the Start/Stop
    /// path and the Settings toggle cannot leave the box in disagreeing states.
    private func applyVisibility() {
        // Don't tear down or fight a live preview's on-screen sample; the preview applies this on close.
        guard display == .log else { return }
        guard shouldBeVisible else { return panel.orderOut(nil) }
        // Re-assert capture exclusion on every show — defense-in-depth against an activation-policy
        // flip dropping `sharingType` (same reason as OverlayCaptionPanel.show).
        reassertCaptureExclusion()
        panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
    }

    /// Follow the session: Start puts the box on screen (if it is switched on), Stop takes it away.
    /// Start also rolls a collapsed box back open, because collapse belongs to the conversation the
    /// user collapsed it during, not to the next one.
    public func setSessionLive(_ live: Bool) {
        isSessionLive = live
        if !live { codeSnippet = nil }
        // Start takes the sample down and Stop can put it back, both without Settings saying anything:
        // whether the preview stands in is derived, not commanded.
        applyDisplay()
        if live { setCollapsed(false) }
        refreshCode()
        applyVisibility()
    }

    // MARK: - OverlayBoxApplying

    public func setDiagramsEnabled(_ enabled: Bool) {
        diagramsEnabled = enabled
        renderDisplay()
    }

    /// Set the box's background-fill opacity (0–1), live. Only the alpha varies; the fill colour stays
    /// constant. The window stays non-opaque so a dimmed fill reads as translucent over what's behind.
    public func setOpacity(_ opacity: Double) {
        box.layer?.backgroundColor = NSColor(white: Self.boxWhite, alpha: CGFloat(opacity)).cgColor
    }

    /// Set the response text's point size, live; the timestamp tracks a couple points smaller.
    public func setFontSize(_ points: Double) {
        fontSize = CGFloat(points)
        renderDisplay()
    }

    /// One callback per finished drag rather than per frame: a per-frame hook would rewrite the
    /// preference dozens of times per gesture.
    private func reportContentSize() {
        let size = panel.contentRect(forFrameRect: panel.frame).size
        // The horizontal edges stay draggable while collapsed, and the height on screen is then the
        // header's — so report the height the user actually chose, never the rolled-up one.
        onSizeChanged?(Double(size.width), Double(isCollapsed ? expandedContentHeight : size.height))
    }

    /// Switch the box on or off, live. It reaches the screen only while a session is also running.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        applyVisibility()
    }

    /// Stand the box up with sample text while the Settings appearance tab is open, so size and
    /// opacity changes have something to show, then restore the real log and the box's prior
    /// visibility. Mirrors `OverlayCaptionPanel.showAppearancePreview`.
    ///
    /// The sample stands in only while stopped. During a session the box is already on screen carrying
    /// the conversation's own tips, and `setFontSize`/`setOpacity` apply to it live, so sample text
    /// would replace real content with something worse. Keeping the two lifecycles apart is also what
    /// stops a tip landing behind a sample, and stops a collapse snapshot crossing a session boundary.
    ///
    /// This records the request rather than acting on it, so a request made during a session is still
    /// standing when the session stops.
    public func showAppearancePreview(_ on: Bool) {
        isPreviewRequested = on
        applyDisplay()
    }

    /// Whether the sample should be standing in: Settings wants it, and no session is running to put
    /// real content on screen instead. One place owns the rule, mirroring `shouldBeVisible`, so the
    /// Settings tab and the Start/Stop path cannot leave the box showing a source neither intended.
    private var wantedDisplay: Display { isPreviewRequested && !isSessionLive ? .sample : .log }

    /// Bring the box to whatever `wantedDisplay` now says. Stopping a session with the Overlay tab
    /// still open puts the sample up on its own, so the sliders are never left with nothing to act on.
    private func applyDisplay() {
        let wanted = wantedDisplay
        guard wanted != display else { return }
        display = wanted
        if wanted == .sample {
            // A collapsed box has no log on screen, so its sample would be invisible and the text-size
            // slider would preview nothing. Roll it open for the preview and restore it on close;
            // collapse is the user's gesture, not something a Settings visit should spend.
            wasCollapsedBeforePreview = isCollapsed
            setCollapsed(false)
            reassertCaptureExclusion()
            renderDisplay()
            panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
        } else {
            renderDisplay()                       // restore the real log…
            textView.scrollToEndOfDocument(nil)   // …scrolled to the newest response
            setCollapsed(wasCollapsedBeforePreview)
            applyVisibility()                     // and whether the box belongs on screen at all
        }
    }

    private func reassertCaptureExclusion() {
        panel.excludeFromScreenCapture()
        captureExclusionReassertCount += 1
    }

    // MARK: - Test hooks (internal; reached via `@testable import JarvisOverlay`)

    /// The panel's current capture-sharing type. `.none` means excluded from screen capture.
    var currentCodeSnippet: CodeSnippet? { codeView.snippet }
    var currentCodeHeight: CGFloat { codeView.frame.height }

    var currentSharingType: NSWindow.SharingType { panel.sharingType }

    /// Number of logged responses — lets tests assert append/clear behavior.
    var entryCount: Int { entries.count }

    /// The full rendered log text (timestamps + responses) — lets tests assert what is shown.
    var currentText: String { textView.string }

    /// Whether the panel is on screen — lets tests assert toggle/show/hide.
    var isPanelVisible: Bool { panel.isVisible }

    /// The box fill's current alpha (the opacity the user picked).
    var currentBoxOpacity: CGFloat { box.layer?.backgroundColor?.alpha ?? 0 }

    /// The response text's current point size (the size the user picked).
    var currentFontPointSize: CGFloat { fontSize }

    /// Whether the box can be resized by dragging its edges.
    var isResizable: Bool { panel.isResizable }

    /// Scroller presentation used by the history box.
    var currentScrollerStyle: NSScroller.Style {
        textView.enclosingScrollView?.scrollerStyle ?? .legacy
    }

    /// Whether a non-scrollable history hides its vertical scroller.
    var scrollersAutohide: Bool {
        textView.enclosingScrollView?.autohidesScrollers ?? false
    }

    /// The box's current content size — lets tests assert resize/min-size behavior.
    var currentContentSize: NSSize { panel.contentRect(forFrameRect: panel.frame).size }

    /// Resize the box's content (used by tests; the user resizes by dragging the edges, and the
    /// restored size arrives through `init`).
    func setContentSize(_ size: NSSize) { panel.setContentSize(size) }

    /// The smallest size a drag can reach — lets tests assert it matches the persisted floor.
    var minimumContentSize: NSSize { panel.minSize }

    /// The largest size a drag can reach — meets the floor while the box is collapsed.
    var maximumContentSize: NSSize { panel.maxSize }

    /// The header strip's height — lets tests assert it tracks the box's size.
    var currentHeaderHeight: CGFloat { header.frame.height }

    /// Whether the log is on screen under the header.
    var isLogVisible: Bool { !scroll.isHidden }

    /// Whether the header is offering the clear button.
    var isClearButtonVisible: Bool { !header.clearButton.isHidden }

    /// Drive the header's own controls, so tests take the path the user takes.
    func clickCollapseButton() { header.collapseButton.performClick(nil) }
    func clickClearButton() { header.clearButton.performClick(nil) }

    /// The panel's frame on screen — lets tests assert that collapsing rolls the box down from a
    /// fixed top edge rather than moving it.
    var currentFrame: NSRect { panel.frame }

    /// Whether the header's controls carry a tooltip. They must not: AppKit draws one in a window of
    /// its own, outside this panel's capture exclusion.
    var headerButtonTooltips: [String?] { [header.collapseButton.toolTip, header.clearButton.toolTip] }

    /// What VoiceOver reads for the header's controls, so dropping the tooltips cannot quietly cost
    /// the buttons their labels too.
    var headerButtonLabels: [String?] {
        [header.collapseButton.accessibilityLabel(), header.clearButton.accessibilityLabel()]
    }

    /// Drives the same AppKit entry point that ends a user resize drag — lets tests assert that a
    /// finished drag is reported exactly once.
    func endLiveResize() { box.viewDidEndLiveResize() }
}

/// The box's content view, which reports the end of a user resize drag.
///
/// AppKit sends `viewDidEndLiveResize` to the views in a window being live-resized, once the drag
/// finishes. Overriding it here rather than assigning `NSWindow.delegate`: a delegate assignment
/// drives AppKit into window-server-dependent setup that blocks indefinitely on a machine with no
/// GUI session, which hung every main-actor test on CI. A view subclass needs none of that
/// machinery, and AppKit calls it only for a real drag — never for a programmatic `setContentSize`.
private final class ResizeReportingView: NSView {
    var onEndLiveResize: (() -> Void)?
    /// Every size change, programmatic or dragged, synchronously — the panel relays the header and
    /// the log off it, and re-renders so a diagram hint is rasterized to the new width. AppKit sends
    /// this before any layout pass, which an offscreen panel never runs.
    var onFrameSizeChanged: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onFrameSizeChanged?()
    }
}

/// An NSTextView that lets a click-drag move the borderless window instead of being swallowed by the
/// text view — so the read-only box is draggable anywhere, while the scroll wheel still scrolls.
private final class MovableTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { true }
}
