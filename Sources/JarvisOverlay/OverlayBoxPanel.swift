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
    /// While the Settings appearance tab is open, the box shows sample text (not the real log) so size
    /// and opacity changes are visible even with no responses yet. Restored on close.
    private var isPreviewing = false
    /// Whether the box was rolled up when the Settings preview opened, so closing it can restore that.
    private var wasCollapsedBeforePreview = false
    /// The Settings toggle: the user's master switch. Off means the box never appears.
    private var isEnabled = false
    /// Whether a coaching session is running. Set by the app on Start and Stop.
    private var isSessionLive = false
    /// Reports the box's new content size once a resize drag finishes.
    public var onSizeChanged: ((Double, Double) -> Void)?
    /// Stand-in responses shown during the Settings preview.
    private static let sampleEntries: [(stamp: String, text: String)] = [
        ("10:30:00", "Ask about the time complexity of that loop."),
        ("10:30:08", "Mention the edge case when the list is empty."),
    ]
    /// Each spoken tip with the time it arrived, newest last. Held as structured entries (not the
    /// rendered string) so `clear()` and the test hooks don't have to parse the text back out.
    private var entries: [(stamp: String, text: String)] = []
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
        box.addSubview(header)
        box.addSubview(affordance)   // topmost, so its tracking area sees the whole box
        panel.contentView = box
        super.init()
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
    }

    // MARK: - Header actions

    @objc private func toggleCollapsed() { setCollapsed(!isCollapsed) }

    /// The preview hides this button, so this guard is the second lock rather than the first: were it
    /// ever reachable while the preview owns the display, clearing would wipe the session's history
    /// with nothing on screen changing to show it had happened.
    @objc private func clearLog() {
        guard !isPreviewing else { return }
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
        let text = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return }
        Task { @MainActor in self.append(text) }
    }

    private func append(_ text: String) {
        entries.append((stamp: timeFormatter.string(from: Date()), text: text))
        guard !isPreviewing else { return }   // the preview owns the display; restored on close
        // Re-assert capture exclusion on every render that reaches the screen — same defense-in-depth as
        // OverlayCaptionPanel.show, since this box can be visible (full of responses) while Settings flips the
        // activation policy and WindowServer drops `sharingType` on vulnerable macOS builds.
        if panel.isVisible { reassertCaptureExclusion() }
        rerender()
        textView.scrollToEndOfDocument(nil)   // keep the newest response in view
    }

    /// Re-render whichever content the box should currently show — sample text while previewing, the
    /// real log otherwise. Called after a font change so the new size is reflected live in both modes.
    private func refreshText() {
        setEntriesText(isPreviewing ? Self.sampleEntries : entries)
    }

    private func rerender() { setEntriesText(entries) }

    /// Build the readout from `items`: a dimmed monospaced timestamp in front of each response, blank
    /// line between.
    private func setEntriesText(_ items: [(stamp: String, text: String)]) {
        let result = NSMutableAttributedString()
        let stampAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1, alpha: 0.5),
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(8, fontSize - 2), weight: .regular),
        ]
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize),
        ]
        for (i, entry) in items.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(string: "\(entry.stamp)  ", attributes: stampAttrs))
            result.append(NSAttributedString(string: entry.text, attributes: textAttrs))
        }
        textView.textStorage?.setAttributedString(result)
        // The preview's sample is not the user's log, so it offers nothing to erase: the clear button
        // stays away rather than sitting there as a control that does nothing.
        header.setHasContent(!isPreviewing && !items.isEmpty)
    }

    // MARK: - Visibility (the Settings toggle, gated on a live session)

    /// Wipe the log. Called on each fresh Start so the box shows only the current conversation,
    /// matching how the session rotates.
    public func clear() {
        entries.removeAll()
        guard !isPreviewing else { return }   // the preview owns the display; restored on close
        rerender()
    }

    /// Whether the box belongs on screen: switched on *and* a session running. Kept distinct from
    /// `panel.isVisible` because the Settings preview can show the box without either being true; the
    /// preview restores to this on close, so the box can never disagree with the setting or outlive Stop.
    private var shouldBeVisible: Bool { isEnabled && isSessionLive }

    /// Bring the panel to whatever `shouldBeVisible` now says. One place owns the rule, so the Start/Stop
    /// path and the Settings toggle cannot leave the box in disagreeing states.
    private func applyVisibility() {
        // Don't tear down or fight a live preview's on-screen sample; the preview applies this on close.
        guard !isPreviewing else { return }
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
        if live { setCollapsed(false) }
        applyVisibility()
    }

    // MARK: - OverlayBoxApplying

    /// Set the box's background-fill opacity (0–1), live. Only the alpha varies; the fill colour stays
    /// constant. The window stays non-opaque so a dimmed fill reads as translucent over what's behind.
    public func setOpacity(_ opacity: Double) {
        box.layer?.backgroundColor = NSColor(white: Self.boxWhite, alpha: CGFloat(opacity)).cgColor
    }

    /// Set the response text's point size, live; the timestamp tracks a couple points smaller.
    public func setFontSize(_ points: Double) {
        fontSize = CGFloat(points)
        refreshText()
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

    /// Show the box with sample text (on) while the Settings appearance tab is open so size/opacity
    /// changes are visible, then restore the real log and the box's prior visibility (off). Re-asserts
    /// capture exclusion, mirroring `OverlayCaptionPanel.showAppearancePreview`.
    public func showAppearancePreview(_ on: Bool) {
        if on {
            isPreviewing = true
            // A collapsed box has no log on screen, so its sample would be invisible and the text-size
            // slider would preview nothing. Roll it open for the preview and restore it on close;
            // collapse is the user's gesture, not something a Settings visit should spend.
            wasCollapsedBeforePreview = isCollapsed
            setCollapsed(false)
            reassertCaptureExclusion()
            setEntriesText(Self.sampleEntries)
            panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
        } else if isPreviewing {
            isPreviewing = false
            rerender()                            // restore the real log…
            textView.scrollToEndOfDocument(nil)   // …scrolled to any responses that arrived during preview
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
    /// the log off it. AppKit sends this before any layout pass, which an offscreen panel never runs.
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
