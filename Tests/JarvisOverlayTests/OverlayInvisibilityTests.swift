import Testing
import AppKit
// @preconcurrency: CI's Xcode toolchain rejects ScreenCaptureKit's non-Sendable async results
// crossing back to the @MainActor helpers.
@preconcurrency import ScreenCaptureKit
@testable import JarvisOverlay

/// Async tests are nonisolated wrappers that `await` a `@MainActor` helper: `@MainActor async
/// @Test` miscompiles on the bundled swift-testing toolchain, while synchronous `@MainActor @Test`
/// is fine.
// Serialized: concurrent captions make each other's main-actor timer observations
// scheduler-dependent.
@Suite(.serialized) struct OverlayInvisibilityTests {

    @MainActor @Test
    func cycleErrorUsesExistingCaptureExcludedCaption() {
        let panel = OverlayCaptionPanel()
        panel.setEnabled(true)
        defer { panel.setEnabled(false) }
        panel.showError("Coaching failed. I'm still listening.")
        #expect(panel.currentText == "Coaching failed. I'm still listening.")
        #expect(panel.currentSharingType == .none)
    }

    @MainActor @Test
    func overlaySetsCaptureExclusionAtInit() {
        let overlay = OverlayCaptionPanel()
        #expect(overlay.currentSharingType == .none)
    }

    @MainActor @Test
    func settersChangeFontAndOpacity() {
        let overlay = OverlayCaptionPanel()
        overlay.setFontSize(26)
        overlay.setBackgroundOpacity(0.5)
        #expect(overlay.currentFontPointSize == 26)
        #expect(abs(overlay.currentBackgroundAlpha - 0.5) < 0.001)
    }

    @MainActor @Test
    func previewReassertsCaptureExclusion() {
        let overlay = OverlayCaptionPanel()
        let before = overlay.captureExclusionReassertCount
        overlay.showAppearancePreview(true)
        #expect(overlay.captureExclusionReassertCount > before, "showAppearancePreview must re-assert capture exclusion")
        #expect(overlay.currentSharingType == .none)
        overlay.showAppearancePreview(false)
        #expect(overlay.currentSharingType == .none)
    }

    @Test
    func overlayReassertsExclusionWhenShown() async {
        await checkReassertOnShow()
    }

    @Test
    func overlayDoesNotShowForEmptyOrWhitespaceLines() async {
        await checkEmptyLinesDoNotShow()
    }

    @Test
    func overlayQueuesTipsInsteadOfInterrupting() async {
        await checkTipsQueue()
    }

    @Test
    func overlayResumesTipAndQueueAfterSettingsPreview() async {
        await checkPreviewResumesTip()
    }

    @Test
    func overlayHidesPanelAfterQueueDrains() async {
        await checkDrainThenHide()
    }

    @Test
    func overlayBlanksBetweenConsecutiveLines() async {
        await checkInterLineGapBlanks()
    }

    @Test
    func overlayExpandsToFitLongText() async {
        await checkPanelGrowsForLongText()
    }

    @Test
    func overlayKeepsPerLineTimesAlignedWhenDroppingEmptyLines() async {
        await checkRenderAlignsTimesWhenDroppingEmptyLines()
    }

    @Test
    func disabledCaptionSuppressesTips() async {
        await checkDisabledCaptionSuppressesTips()
    }

    @Test
    func reEnabledCaptionShowsTipsAgain() async {
        await checkReEnabledCaptionShowsTips()
    }

    @Test
    func disablingMidTipHidesTheCaption() async {
        await checkDisablingMidTipHides()
    }

    @Test
    func disablingDuringPreviewStaysOffOnClose() async {
        await checkDisableDuringPreviewStaysOff()
    }

    @MainActor @Test
    func disabledCaptionStillPreviews() {
        let overlay = OverlayCaptionPanel()
        overlay.setEnabled(false)
        overlay.showAppearancePreview(true)
        #expect(overlay.currentText == "Sample overlay text", "the preview sample must show even when the caption is off")
        #expect(overlay.isPanelVisible)
        overlay.showAppearancePreview(false)
        #expect(!overlay.isPanelVisible, "closing the preview restores the off (hidden) state")
        #expect(overlay.currentSharingType == .none)
    }

    @MainActor @Test
    func overlayPreviewWithEmptyQueueHidesOnCloseAndTogglesCleanly() {
        let overlay = OverlayCaptionPanel()
        overlay.showAppearancePreview(true)
        #expect(overlay.currentText == "Sample overlay text")
        overlay.showAppearancePreview(false)
        #expect(!overlay.isPanelVisible, "closing an empty-queue preview must hide the panel")
        overlay.showAppearancePreview(true)
        overlay.showAppearancePreview(false)
        #expect(!overlay.isPanelVisible)
        #expect(overlay.currentSharingType == .none)
    }

    // A condition trait, not an early return, so opting out reports skipped rather than passed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_RUN_CAPTURE_TESTS"] == "1",
                   "opt-in: set JARVIS_RUN_CAPTURE_TESTS=1 and grant Screen Recording to run the live capture test"))
    func protectedWindowIsExcludedFromScreenCaptureKit() async {
        await checkScreenCaptureKitExclusion()
    }
}

// MARK: - Helpers

// Polls because a fixed sleep races the real DispatchQueue.main timer on a loaded runner.
@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let steps = max(1, Int(timeout / 0.02))
    for _ in 0..<steps {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: - Main-actor checks (called via `await` from the nonisolated tests)

@MainActor
private func checkReassertOnShow() async {
    // macOS 26 won't hold a non-`.none` sharingType, so a dropped flag can't be simulated; count
    // re-asserts.
    let overlay = OverlayCaptionPanel()
    let before = overlay.captureExclusionReassertCount

    overlay.render(["Stay hidden.", "Even after a reset."], perLineSeconds: 0.05)
    #expect(await waitUntil { overlay.captureExclusionReassertCount > before }, "render() must re-assert capture exclusion")
    #expect(overlay.currentSharingType == .none)
}

@MainActor
private func checkEmptyLinesDoNotShow() async {
    let overlay = OverlayCaptionPanel()
    let before = overlay.captureExclusionReassertCount

    overlay.render([], perLineSeconds: 0.05)
    overlay.render(["   ", "", "\n\t"], perLineSeconds: 0.05)
    try? await Task.sleep(nanoseconds: 200_000_000)   // lets an erroneous main-actor hop run

    #expect(overlay.captureExclusionReassertCount == before,
            "empty/whitespace-only lines must not show the overlay")
}

@MainActor
private func checkTipsQueue() async {
    let overlay = OverlayCaptionPanel()
    let hold: TimeInterval = 3   // long enough that "first" can't advance before we check it

    overlay.render(["first"], perLineSeconds: hold)
    overlay.render(["second"], perLineSeconds: hold)

    #expect(await waitUntil { overlay.currentText == "first" }, "the first tip should display")
    #expect(overlay.currentText == "first", "a newer tip must not interrupt one still on screen")

    #expect(await waitUntil(timeout: hold + 2) { overlay.currentText == "second" },
            "the queued tip must display after the first finishes")
}

@MainActor
private func checkDrainThenHide() async {
    let overlay = OverlayCaptionPanel()
    overlay.interLineGapSeconds = 0

    overlay.render(["only"], perLineSeconds: 0.3)
    #expect(await waitUntil { overlay.isPanelVisible }, "the tip should be on screen while displaying")
    #expect(await waitUntil { !overlay.isPanelVisible }, "the panel must hide once the queue drains")

    overlay.render(["again"], perLineSeconds: 0.3)
    #expect(await waitUntil { overlay.currentText == "again" }, "state must reset so the next tip shows")
    #expect(overlay.isPanelVisible)
}

@MainActor
private func checkInterLineGapBlanks() async {
    let overlay = OverlayCaptionPanel()
    overlay.interLineGapSeconds = 0.5   // long enough to see the panel still up once the blank is caught

    overlay.render(["L1", "L2"], perLineSeconds: 0.4)
    #expect(await waitUntil { overlay.currentText == "L1" }, "the first line should be up before the gap")
    #expect(await waitUntil { overlay.currentText == "" }, "the panel must blank between consecutive lines")
    #expect(overlay.isPanelVisible, "the gap must blank the TEXT while the panel stays on screen — not hide it")
    #expect(await waitUntil { overlay.currentText == "L2" }, "the next line must appear after the gap")
}

// Three lengths because single-line measurement would floor both medium and long at 80pt.
// Fixtures have no trailing whitespace: render() trims it, which would desync currentText.
@MainActor
private func checkPanelGrowsForLongText() async {
    let overlay = OverlayCaptionPanel()
    overlay.interLineGapSeconds = 0

    let short = "Nod."
    let medium = String(repeating: "This is a coaching tip that wraps onto a few rows.", count: 4)
    let long = String(repeating: "This is a long coaching tip that must wrap onto several lines.", count: 8)

    overlay.render([short], perLineSeconds: 0.3)
    #expect(await waitUntil { overlay.currentText == short }, "the short line should display")
    let shortHeight = overlay.currentPanelHeight
    let bottomEdge = overlay.currentPanelBottom
    #expect(shortHeight == 80, "a short line stays at the floor height (got \(shortHeight))")

    overlay.render([medium], perLineSeconds: 0.3)
    #expect(await waitUntil { overlay.currentText == medium }, "the medium line should display")
    let mediumHeight = overlay.currentPanelHeight
    #expect(mediumHeight > shortHeight,
            "a multi-row line must clear the floor — proves real wrapped-height measurement (got \(mediumHeight)pt)")
    #expect(overlay.currentPanelBottom == bottomEdge,
            "the panel must grow upward — its bottom edge stays pinned (got \(overlay.currentPanelBottom), was \(bottomEdge))")

    overlay.render([long], perLineSeconds: 3)
    #expect(await waitUntil { overlay.currentText == long }, "the long line should display")
    #expect(overlay.currentPanelHeight > mediumHeight,
            "a longer line wraps to more rows and must be taller still — proves height scales with row count (got \(overlay.currentPanelHeight)pt)")
    #expect(overlay.currentPanelBottom == bottomEdge,
            "the bottom edge must stay pinned as the panel grows taller (got \(overlay.currentPanelBottom), was \(bottomEdge))")
    #expect(overlay.currentSharingType == .none,
            "the panel must stay excluded from screen capture after the resize")
}

@MainActor
private func checkRenderAlignsTimesWhenDroppingEmptyLines() async {
    let overlay = OverlayCaptionPanel()
    overlay.interLineGapSeconds = 0

    // A misaligned zip would give the survivor 0.1s. Its 3.0s must dwarf the 0.25s recheck plus
    // main-actor latency on a loaded runner.
    overlay.render(["   ", "survivor"], perLineSeconds: [0.1, 3.0])
    #expect(await waitUntil { overlay.currentText == "survivor" }, "the surviving line must appear")
    try? await Task.sleep(nanoseconds: 250_000_000)
    #expect(overlay.currentText == "survivor", "the surviving line must keep ITS own duration, not the dropped line's")
    #expect(overlay.isPanelVisible)
}

@MainActor
private func checkPreviewResumesTip() async {
    let overlay = OverlayCaptionPanel()
    overlay.interLineGapSeconds = 0

    overlay.render(["A1", "A2"], perLineSeconds: 0.6)
    #expect(await waitUntil { overlay.currentText == "A1" }, "the first line should be up")
    overlay.showAppearancePreview(true)
    overlay.render(["B1"], perLineSeconds: 0.6)
    #expect(await waitUntil { overlay.currentText == "Sample overlay text" }, "preview must own the panel while open")

    overlay.showAppearancePreview(false)
    #expect(await waitUntil { overlay.currentText == "A2" }, "the paused tip must resume its remaining line, not be dropped")
    #expect(await waitUntil { overlay.currentText == "B1" }, "a tip that arrived during preview must play after the resumed tip")
}

@MainActor
private func checkDisabledCaptionSuppressesTips() async {
    let overlay = OverlayCaptionPanel()
    overlay.setEnabled(false)
    let before = overlay.captureExclusionReassertCount

    overlay.render(["This must not appear."], perLineSeconds: 0.05)
    try? await Task.sleep(nanoseconds: 200_000_000)   // lets an erroneous main-actor hop run

    #expect(overlay.captureExclusionReassertCount == before, "a disabled caption must not show any tip")
    #expect(!overlay.isPanelVisible)
}

@MainActor
private func checkReEnabledCaptionShowsTips() async {
    let overlay = OverlayCaptionPanel()
    overlay.setEnabled(false)
    overlay.setEnabled(true)
    overlay.render(["Back on."], perLineSeconds: 0.3)
    #expect(await waitUntil { overlay.currentText == "Back on." }, "a re-enabled caption must display tips again")
    #expect(overlay.isPanelVisible)
}

@MainActor
private func checkDisablingMidTipHides() async {
    let overlay = OverlayCaptionPanel()
    overlay.render(["On screen for a while."], perLineSeconds: 5)   // long window so it can't self-advance
    #expect(await waitUntil { overlay.isPanelVisible }, "the tip should be on screen first")
    overlay.setEnabled(false)
    #expect(!overlay.isPanelVisible, "disabling the caption must hide an in-flight tip immediately")
}

@MainActor
private func checkDisableDuringPreviewStaysOff() async {
    let overlay = OverlayCaptionPanel()
    overlay.interLineGapSeconds = 0
    // Two lines so one is still pending when the preview pauses; a single-line tip can't reproduce
    // the bug.
    overlay.render(["Line one, paused.", "Line two, must be dropped."], perLineSeconds: 5)
    #expect(await waitUntil { overlay.currentText == "Line one, paused." }, "the first line should display")
    overlay.showAppearancePreview(true)
    #expect(await waitUntil { overlay.currentText == "Sample overlay text" }, "the preview must own the panel")
    overlay.setEnabled(false)
    overlay.showAppearancePreview(false)
    #expect(!overlay.isPanelVisible, "a caption switched off during preview must stay hidden on close, not resume the tip")
    #expect(overlay.currentText != "Line two, must be dropped.", "the pending line must not be shown on a disabled caption")
}

@MainActor
private func checkScreenCaptureKitExclusion() async {
    guard CGPreflightScreenCaptureAccess() else {
        Issue.record("JARVIS_RUN_CAPTURE_TESTS=1 is set but this process lacks Screen Recording permission — grant it to the terminal and re-run.")
        return
    }
    guard let screen = NSScreen.main else { Issue.record("no main screen"); return }

    // Rare, well-separated colors so ordinary UI pixels can't match.
    let protectedColor: (r: UInt8, g: UInt8, b: UInt8) = (123, 47, 201)
    let controlColor:   (r: UInt8, g: UInt8, b: UInt8) = (47, 201, 123)

    let f = screen.frame
    let protectedPanel = makeSolidPanel(color: protectedColor, protected: true,
                                        rect: NSRect(x: f.minX + 140, y: f.minY + 380, width: 900, height: 240))
    let controlPanel = makeSolidPanel(color: controlColor, protected: false,
                                      rect: NSRect(x: f.minX + 140, y: f.minY + 90, width: 900, height: 240))
    defer { protectedPanel.orderOut(nil); controlPanel.orderOut(nil) }

    try? await Task.sleep(nanoseconds: 700_000_000)   // let the windows render before capturing

    let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screenNumber }) ?? content.displays.first else {
            Issue.record("no SCDisplay"); return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        // Wide tolerance: the sRGB fill round-trips through the display profile before the
        // deviceRGB scan.
        let counts = countMatchingPixels(image, targets: [protectedColor, controlColor], tolerance: 40, step: 3)
        let protectedCount = counts[0]
        let controlCount = counts[1]

        #expect(controlCount > 500,
                "control window not found in capture (\(controlCount) px) — capture or display mapping is wrong")
        #expect(controlCount > protectedCount * 20,
                "sharingType=.none window LEAKED into ScreenCaptureKit (protected=\(protectedCount) px, control=\(controlCount) px) — the overlay would be visible in a screen share")
    } catch {
        Issue.record("ScreenCaptureKit capture failed: \(error)")
    }
}

// MARK: - Helpers

@MainActor
private func makeSolidPanel(color: (r: UInt8, g: UInt8, b: UInt8), protected: Bool, rect: NSRect) -> NSPanel {
    let panel = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = true
    panel.backgroundColor = NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                    blue: CGFloat(color.b) / 255, alpha: 1)
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    if protected { panel.sharingType = .none }
    panel.orderFrontRegardless()
    return panel
}

private func countMatchingPixels(_ image: CGImage,
                                 targets: [(r: UInt8, g: UInt8, b: UInt8)],
                                 tolerance: Int, step: Int) -> [Int] {
    let w = image.width, h = image.height
    let bytesPerRow = w * 4
    var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
    var counts = [Int](repeating: 0, count: targets.count)
    buf.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = base.assumingMemoryBound(to: UInt8.self)   // read via the pointer, not `buf` (exclusivity)
        var y = 0
        while y < h {
            let row = y * bytesPerRow
            var x = 0
            while x < w {
                let p = row + x * 4
                let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
                for (i, t) in targets.enumerated() {
                    if abs(r - Int(t.r)) <= tolerance, abs(g - Int(t.g)) <= tolerance, abs(b - Int(t.b)) <= tolerance {
                        counts[i] += 1
                    }
                }
                x += step
            }
            y += step
        }
    }
    return counts
}
