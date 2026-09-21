import AppKit
import JarvisCore

@MainActor
public final class OverlayBoxPanel: NSObject, OverlayRendering, OverlayBoxApplying {
    private let panel: NSPanel
    private let box: ResizeReportingView
    private let textView: NSTextView
    private let historyBackground = NSView(frame: .zero)
    private var detailFontSize = CGFloat(Defaults.Overlay.Detail.fontSize)
    private let detailView: DetailView
    private let detailDivider = OverlayDetailDividerView(frame: .zero)
    /// A user-selected proportion takes precedence over content sizing for this session.
    private var detailHeightFraction: CGFloat?
    private var details: [(stamp: String, detail: ReplyDetail)] = []
    private var slot = DetailSlot()
    private static let sampleDetail = ReplyDetail(markdown: """
        An empty list has no first item. Handle that case before indexing into it.

        ```swift
        guard !items.isEmpty else { return nil }
        let first = items[0]
        ```
        """)
    private let header: OverlayBoxHeaderView
    private let scroll: NSScrollView
    private let resizeAffordance: OverlayBoxResizeAffordanceView
    private(set) var isCollapsed = false
    private var expandedContentHeight: CGFloat
    private static let heightFloor = CGFloat(Defaults.Overlay.Box.heightRange.lowerBound)
    private var chrome: OverlayBoxChrome { OverlayBoxChrome(contentHeight: expandedContentHeight) }
    private static let boxWhite: CGFloat = 0.10
    private var fontSize: CGFloat = CGFloat(Defaults.Overlay.Box.fontSize)
    /// Derive everything shown from this in `renderDisplay`, never from call-site checks.
    private enum Display { case log, sample }
    private var display: Display = .log
    /// Recorded rather than obeyed: Settings cannot see whether a session is running.
    private var isPreviewRequested = false
    private var wasCollapsedBeforePreview = false
    private var isEnabled = false
    private var isSessionLive = false
    /// Called with the content width and height once a resize drag finishes.
    public var onSizeChanged: ((Double, Double) -> Void)?
    private static let sampleEntries: [(stamp: String, text: String, hasDetail: Bool)] = [
        ("10:30:00", "Ask about the time complexity of that loop.", false),
        ("10:30:08", "Check the empty list before reading its first item.", true),
    ]
    private var latestEntryStart = 0
    private var entries: [(stamp: String, text: String, hasDetail: Bool)] = []
    private(set) var captureExclusionReassertCount = 0

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Takes the restored size up front: `setContentSize` pins the top-left, so resizing after
    /// `center()` would leave the box off-centre. Never query `NSScreen` here: it blocks AppKit
    /// on a host with no GUI session and hangs every main-actor test.
    public init(contentSize: NSSize = NSSize(
        width: Defaults.Overlay.Box.width,
        height: Defaults.Overlay.Box.height)
    ) {
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = ResizeReportingView(frame: panel.contentRect(forFrameRect: panel.frame))
        box.wantsLayer = true
        // Separate fills keep the history's opacity from showing through the detail backdrop.
        historyBackground.wantsLayer = true
        historyBackground.layer?.backgroundColor = NSColor(
            white: Self.boxWhite,
            alpha: CGFloat(Defaults.Overlay.Box.opacity)).cgColor
        box.addSubview(historyBackground)
        box.layer?.cornerRadius = OverlayBoxChrome.cornerRadius
        box.layer?.masksToBounds = true
        self.box = box

        let scroll = NSScrollView(frame: box.bounds)
        scroll.hasVerticalScroller = true
        // AppKit's default scroller style varies by SDK and input device, so set it explicitly.
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // Not selectable, so a click-drag on the text moves the window instead of selecting.
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

        let chrome = OverlayBoxChrome(contentHeight: contentSize.height)
        let header = OverlayBoxHeaderView(chrome: chrome)
        self.header = header
        detailView = DetailView(frame: .zero, chrome: chrome)
        expandedContentHeight = contentSize.height
        let affordance = OverlayBoxResizeAffordanceView(frame: box.bounds)
        resizeAffordance = affordance

        box.addSubview(scroll)
        box.addSubview(detailView)
        box.addSubview(detailDivider)
        detailView.isHidden = true
        box.addSubview(header)
        box.addSubview(affordance)   // topmost, so its tracking area sees the whole box
        panel.contentView = box
        super.init()
        detailDivider.onHeightChanged = { [weak self] height in
            guard let self, !self.detailDivider.isHidden else { return }
            let available = max(0, self.box.bounds.height - self.chrome.height)
            guard available > 0 else { return }
            self.detailHeightFraction = self.boundedDetailHeight(height, available: available) / available
            self.layoutDetails()
        }
        // The detail controls act on the session's slot, so they ignore the Settings sample.
        detailView.onPrevious = { [weak self] in self?.step(by: -1) }
        detailView.onNext = { [weak self] in self?.step(by: 1) }
        detailView.onTogglePin = { [weak self] in
            guard let self, self.display == .log else { return }
            if self.slot.isHeld {
                self.slot.unpin(newest: self.shownDetails.isEmpty ? nil : self.shownDetails.count - 1)
            } else {
                self.slot.pin()
            }
            self.refreshDetails()
        }
        detailView.onToggleRolled = { [weak self] in
            guard let self, self.display == .log else { return }
            self.slot.roll(!self.slot.isRolled)
            self.refreshDetails()
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
        panel.center()
        panel.excludeFromScreenCapture()
    }

    private func layoutContent() {
        let bounds = box.bounds
        if !isCollapsed { expandedContentHeight = bounds.height }
        header.apply(chrome)
        detailView.apply(chrome)
        header.frame = NSRect(x: 0, y: bounds.height - chrome.height,
                              width: bounds.width, height: chrome.height)
        scroll.frame = NSRect(x: 0, y: 0,
                              width: bounds.width, height: max(0, bounds.height - chrome.height))
        resizeAffordance.frame = bounds
        renderDisplay()
    }

    // MARK: - Header actions

    @objc private func toggleCollapsed() { setCollapsed(!isCollapsed) }

    /// Unlike `clear()`, declines while the sample shows, so it never wipes an off-screen log.
    @objc private func clearLog() {
        guard display == .log else { return }
        clear()
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        header.setCollapsed(collapsed)
        resizeAffordance.allowsVerticalResize = !collapsed
        scroll.isHidden = collapsed

        let collapsedHeight = chrome.height
        // Set both limits before the resize so neither clamps it.
        panel.minSize = NSSize(
            width: panel.minSize.width,
            height: collapsed ? collapsedHeight : Self.heightFloor)
        panel.maxSize = NSSize(width: panel.maxSize.width,
                               height: collapsed ? collapsedHeight : .greatestFiniteMagnitude)

        // Anchor the top edge explicitly: `setContentSize` pins the top-left only while the window
        // is on screen, and the bottom-left once Stop has ordered it out.
        let frame = panel.frame          // borderless: the frame is the content rect
        let height = collapsed ? collapsedHeight : expandedContentHeight
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height,
                              width: frame.width, height: height),
                       display: true)
    }

    // MARK: - OverlayRendering

    public nonisolated func render(_ lines: [String]) {
        render(lines, detail: nil)
    }

    public nonisolated func render(_ lines: [String], detail: ReplyDetail?) {
        let summary = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !summary.isEmpty else { return }
        Task { @MainActor in
            self.append(summary, detail: detail)
        }
    }

    private var shownDetails: [(stamp: String, detail: ReplyDetail)] {
        guard display == .sample else { return details }
        return Self.sampleDetail.map { [(stamp: Self.sampleEntries[1].stamp, detail: $0)] } ?? []
    }

    public func showPreviousDetail() {
        guard isSessionLive, isEnabled, !isCollapsed, display == .log else { return }
        detailView.previousButton.performClick(nil)
    }

    public func showNextDetail() {
        guard isSessionLive, isEnabled, !isCollapsed, display == .log else { return }
        detailView.nextButton.performClick(nil)
    }

    private func step(by offset: Int) {
        guard display == .log else { return }
        let available = shownDetails
        guard !available.isEmpty else { return }
        let from = slot.shownIndex ?? available.count - 1
        let target = min(max(0, from + offset), available.count - 1)
        slot.step(to: target, isNewest: target == available.count - 1)
        refreshDetails()
    }

    private func refreshDetails() {
        let available = shownDetails
        let index = display == .sample
            ? (available.isEmpty ? nil : available.count - 1)
            : slot.shownIndex.map { min($0, max(0, available.count - 1)) }
        let entry = index.flatMap { available.indices.contains($0) ? available[$0] : nil }
        detailView.show(entry?.detail, stamp: entry?.stamp ?? "",
                        position: index.map { ($0, available.count) },
                        isHeld: slot.isHeld, isRolled: slot.isRolled,
                        fontSize: detailFontSize,
                        enabled: entry != nil && !isCollapsed)
        layoutDetails()
    }

    private func boundedDetailHeight(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        // At the minimum panel size, preserving a hint line takes priority over the detail floor.
        min(max(0, available - 44), max(96, proposed))
    }

    private func layoutDetails() {
        let available = max(0, box.bounds.height - chrome.height)
        detailDivider.isHidden = detailView.isHidden
        let height: CGFloat
        if detailView.isHidden {
            height = 0
        } else if slot.isRolled {
            height = min(available, detailView.stripHeight)
        } else {
            let automatic: CGFloat
            if detailView.detail?.diagram != nil {
                automatic = max(0, available - max(72, fontSize * 3 + 24))
            } else {
                let ceiling = box.bounds.height * 0.45
                automatic = min(ceiling, detailView.preferredHeight(
                    viewportWidth: box.bounds.width,
                    viewportHeight: max(1, ceiling - detailView.stripHeight)))
            }
            let preferred = detailHeightFraction.map { $0 * available } ?? automatic
            height = boundedDetailHeight(preferred, available: available)
        }
        historyBackground.frame = NSRect(x: 0, y: height, width: box.bounds.width,
                                         height: max(0, box.bounds.height - height))
        detailView.frame = NSRect(x: 0, y: 0, width: box.bounds.width, height: height)
        detailView.needsLayout = true
        detailView.layoutSubtreeIfNeeded()
        // Straddle the boundary so the grab target does not eat into a small panel's content.
        let dividerHeight = OverlayDetailDividerView.thickness
        detailDivider.frame = NSRect(x: 0, y: height - dividerHeight / 2,
                                     width: box.bounds.width, height: dividerHeight)
        scroll.frame = NSRect(x: 0, y: height, width: box.bounds.width,
                              height: max(0, available - height))
    }

    /// Returns the detail actually shown, nil when the box can't show one, so an unseen detail is
    /// never recorded as delivered or replayed to the model.
    public func deliver(_ lines: [String], detail: ReplyDetail?) -> ReplyDetail? {
        let summary = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !summary.isEmpty else { return nil }
        let shown = acceptsDetail ? detail.flatMap { $0.hasContent ? $0 : nil } : nil
        append(summary, detail: shown)
        return shown
    }

    private func append(_ text: String, detail: ReplyDetail?) {
        entries.append((stamp: timeFormatter.string(from: Date()),
                        text: text, hasDetail: detail != nil))
        if let detail, detail.hasContent {
            details.append((stamp: entries[entries.count - 1].stamp, detail: detail))
            slot.received(details.count - 1)
        }
        // An activation-policy flip can drop `sharingType` while the box is visible, so re-assert.
        if panel.isVisible { reassertCaptureExclusion() }
        renderDisplay()
        if detail != nil {
            // Scroll to the newest hint's start, not the end, so its detail marker stays in view.
            if let layout = textView.layoutManager, let container = textView.textContainer {
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(
                    forCharacterRange: NSRange(location: latestEntryStart, length: 1), actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                textView.scroll(NSPoint(x: 0, y: rect.minY + textView.textContainerInset.height))
            }
        } else {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func renderDisplay() {
        let items = display == .sample ? Self.sampleEntries : entries
        let result = NSMutableAttributedString()
        let stampAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1, alpha: 0.5),
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(8, fontSize - 2), weight: .regular),
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1, alpha: 0.5),
            .font: NSFont.systemFont(ofSize: max(8, fontSize - 2), weight: .regular),
        ]
        for (i, entry) in items.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n\n")) }
            latestEntryStart = result.length
            result.append(NSAttributedString(string: "\(entry.stamp)  ", attributes: stampAttrs))
            result.append(NSAttributedString(string: entry.text, attributes: hintAttrs))
            if entry.hasDetail {
                result.append(NSAttributedString(string: "  detail below", attributes: markerAttrs))
            }
        }
        textView.textStorage?.setAttributedString(result)
        header.setHasContent(display == .log && !entries.isEmpty)
        refreshDetails()
    }

    // MARK: - Visibility (the Settings toggle, gated on a live session)

    /// A held detail survives.
    public func clear() {
        entries.removeAll()
        if !slot.isHeld {
            details.removeAll()
            slot.reset()
        }
        renderDisplay()
    }

    public var acceptsDetail: Bool { shouldBeVisible && !isCollapsed }

    /// Not `panel.isVisible`: the Settings preview can show the box while this is false.
    private var shouldBeVisible: Bool { isEnabled && isSessionLive }

    private func applyVisibility() {
        // The preview applies this on close; don't tear down its sample.
        guard display == .log else { return }
        guard shouldBeVisible else { return panel.orderOut(nil) }
        // An activation-policy flip can drop `sharingType`, so re-assert on every show.
        reassertCaptureExclusion()
        panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
    }

    public func setSessionLive(_ live: Bool) {
        if live && !isSessionLive { detailHeightFraction = nil }
        isSessionLive = live
        if !live {
            details.removeAll()
            slot.reset()
        }
        applyDisplay()
        if live { setCollapsed(false) }
        refreshDetails()
        applyVisibility()
    }

    // MARK: - OverlayBoxApplying

    public func setDetailFontSize(_ points: Double) {
        detailFontSize = CGFloat(points)
        refreshDetails()
    }

    public func setDetailBackgroundOpacity(_ opacity: Double) {
        detailView.layer?.backgroundColor =
            DetailView.background.withAlphaComponent(CGFloat(opacity)).cgColor
    }

    public func setOpacity(_ opacity: Double) {
        historyBackground.layer?.backgroundColor = NSColor(white: Self.boxWhite, alpha: CGFloat(opacity)).cgColor
    }

    public func setFontSize(_ points: Double) {
        fontSize = CGFloat(points)
        renderDisplay()
    }

    /// Once per finished drag, never per frame, so the preference isn't rewritten mid-gesture.
    private func reportContentSize() {
        let size = panel.contentRect(forFrameRect: panel.frame).size
        onSizeChanged?(Double(size.width), Double(isCollapsed ? expandedContentHeight : size.height))
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        applyVisibility()
    }

    /// Recorded rather than applied, so a request made during a session takes effect when it stops.
    public func showAppearancePreview(_ on: Bool) {
        isPreviewRequested = on
        applyDisplay()
    }

    private var wantedDisplay: Display { isPreviewRequested && !isSessionLive ? .sample : .log }

    private func applyDisplay() {
        let wanted = wantedDisplay
        guard wanted != display else { return }
        display = wanted
        if wanted == .sample {
            wasCollapsedBeforePreview = isCollapsed
            setCollapsed(false)
            reassertCaptureExclusion()
            renderDisplay()
            panel.orderFrontRegardless() // ghost-mode-allowed: capture-excluded coaching overlay
        } else {
            renderDisplay()
            textView.scrollToEndOfDocument(nil)
            setCollapsed(wasCollapsedBeforePreview)
            applyVisibility()
        }
    }

    private func reassertCaptureExclusion() {
        panel.excludeFromScreenCapture()
        captureExclusionReassertCount += 1
    }

    // MARK: - Test hooks (internal; reached via `@testable import JarvisOverlay`)

    var currentDetail: ReplyDetail? { detailView.detail }
    var currentDetailHeight: CGFloat { detailView.frame.height }
    var currentDetailTitle: String { detailView.titleText }
    var currentDetailPosition: String { detailView.positionText }
    var currentDetailCodeText: NSAttributedString { detailView.codeText }
    var currentDetailProseText: String { detailView.proseText }
    var showsDiagram: Bool { !detailView.isHidden && detailView.showsDiagram }
    var isDetailRolled: Bool { detailView.isRolled }
    var detailStripHeight: CGFloat { detailView.stripHeight }
    var detailIconPointSize: CGFloat { detailView.iconPointSize }
    var detailTitlePointSize: CGFloat { detailView.titlePointSize }
    var headerIconPointSize: CGFloat { header.iconPointSize }
    var headerTitlePointSize: CGFloat { header.titlePointSize }
    var isDetailHeld: Bool { slot.isHeld }
    var detailCount: Int { details.count }

    func clickDetailPrevious() { detailView.previousButton.performClick(nil) }
    func clickDetailNext() { detailView.nextButton.performClick(nil) }
    func clickDetailPin() { detailView.pinButton.performClick(nil) }
    func clickDetailDismiss() { detailView.dismissButton.performClick(nil) }

    var detailButtonTooltips: [String?] {
        [detailView.previousButton.toolTip, detailView.nextButton.toolTip,
         detailView.pinButton.toolTip, detailView.dismissButton.toolTip]
    }

    var detailButtonLabels: [String?] {
        [detailView.previousButton.accessibilityLabel(), detailView.nextButton.accessibilityLabel(),
         detailView.pinButton.accessibilityLabel(), detailView.dismissButton.accessibilityLabel()]
    }

    var currentSharingType: NSWindow.SharingType { panel.sharingType }

    var entryCount: Int { entries.count }

    var currentText: String { textView.string }

    var isPanelVisible: Bool { panel.isVisible }

    var currentBoxOpacity: CGFloat { historyBackground.layer?.backgroundColor?.alpha ?? 0 }
    var currentDetailBackgroundOpacity: CGFloat { detailView.layer?.backgroundColor?.alpha ?? 0 }

    var currentFontPointSize: CGFloat { fontSize }

    var isResizable: Bool { panel.isResizable }

    var currentScrollerStyle: NSScroller.Style {
        textView.enclosingScrollView?.scrollerStyle ?? .legacy
    }

    var scrollersAutohide: Bool {
        textView.enclosingScrollView?.autohidesScrollers ?? false
    }

    var currentContentSize: NSSize { panel.contentRect(forFrameRect: panel.frame).size }

    func setContentSize(_ size: NSSize) { panel.setContentSize(size) }

    var minimumContentSize: NSSize { panel.minSize }

    var maximumContentSize: NSSize { panel.maxSize }

    var currentHeaderHeight: CGFloat { header.frame.height }

    var isLogVisible: Bool { !scroll.isHidden }

    var isClearButtonVisible: Bool { !header.clearButton.isHidden }

    func clickCollapseButton() { header.collapseButton.performClick(nil) }
    func clickClearButton() { header.clearButton.performClick(nil) }

    var currentFrame: NSRect { panel.frame }

    var headerButtonTooltips: [String?] { [header.collapseButton.toolTip, header.clearButton.toolTip] }

    var headerButtonLabels: [String?] {
        [header.collapseButton.accessibilityLabel(), header.clearButton.accessibilityLabel()]
    }

    func endLiveResize() { box.viewDidEndLiveResize() }
}

/// Overrides `viewDidEndLiveResize` instead of setting `NSWindow.delegate`: a delegate assignment
/// blocks indefinitely on a host with no GUI session and hung every main-actor test on CI.
private final class ResizeReportingView: NSView {
    var onEndLiveResize: (() -> Void)?
    /// Fires synchronously on every size change, before any layout pass, which an offscreen panel
    /// never runs.
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

/// A plain `NSTextView` swallows the drag that should move the borderless window.
private final class MovableTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { true }
}
