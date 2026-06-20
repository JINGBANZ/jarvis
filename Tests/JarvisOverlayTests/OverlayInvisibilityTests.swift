import Testing
import AppKit
// @preconcurrency: on the Xcode toolchain (used by CI) ScreenCaptureKit's async results are
// non-Sendable and would otherwise error when crossing back to the @MainActor helper. The CLT
// toolchain is laxer; this keeps both green.
@preconcurrency import ScreenCaptureKit
@testable import JarvisOverlay

/// Regression tests for the overlay's screen-capture invisibility (see wiki/overlay-invisibility.md).
///
/// Two layers:
///   1. Fast property tests — verify `OverlayPanel` sets `sharingType = .none` and *re-asserts* it on
///      `render()`. No screen-recording permission needed, so they run everywhere (including CI) and
///      catch the most likely regression: the flag being removed or the re-assert deleted.
///   2. On-screen capture test — actually captures the screen with ScreenCaptureKit (the API
///      Zoom/Meet/Teams use) and proves a `.none` window is excluded while a control window is not.
///      Needs a GUI session + Screen Recording permission, which CI can't grant, so it is opt-in:
///      run with `JARVIS_RUN_CAPTURE_TESTS=1 ./scripts/run-tests.sh`. Otherwise it returns early.
///
/// Note: only the `@MainActor` + `async` `@Test` *combination* miscompiles on the bundled
/// swift-testing toolchain ("global variable must be a compile-time constant to use @section"); a
/// synchronous `@MainActor @Test` (like `overlaySetsCaptureExclusionAtInit` below) is fine. And
/// XCTest isn't available on a Command-Line-Tools-only install. So the *async* tests are nonisolated
/// `@Test`s that `await` a `@MainActor` helper — keeping the AppKit work on the main actor while
/// sidestepping the bug.
@Suite struct OverlayInvisibilityTests {

    @MainActor @Test
    func overlaySetsCaptureExclusionAtInit() {
        let overlay = OverlayPanel()
        #expect(overlay.currentSharingType == .none)
    }

    @MainActor @Test
    func settersChangeFontAndOpacity() {
        let overlay = OverlayPanel()
        overlay.setFontSize(26)
        overlay.setBackgroundOpacity(0.5)
        #expect(overlay.currentFontPointSize == 26)
        #expect(abs(overlay.currentBackgroundAlpha - 0.5) < 0.001)
    }

    @MainActor @Test
    func previewReassertsCaptureExclusion() {
        let overlay = OverlayPanel()
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
    func overlayKeepsPerLineTimesAlignedWhenDroppingEmptyLines() async {
        await checkRenderAlignsTimesWhenDroppingEmptyLines()
    }

    @MainActor @Test
    func overlayPreviewWithEmptyQueueHidesOnCloseAndTogglesCleanly() {
        let overlay = OverlayPanel()
        // Preview with nothing queued, toggled twice: must not crash, must end hidden and excluded.
        overlay.showAppearancePreview(true)
        #expect(overlay.currentText == "Sample overlay text")
        overlay.showAppearancePreview(false)
        #expect(!overlay.isPanelVisible, "closing an empty-queue preview must hide the panel")
        overlay.showAppearancePreview(true)
        overlay.showAppearancePreview(false)
        #expect(!overlay.isPanelVisible)
        #expect(overlay.currentSharingType == .none)
    }

    // Condition trait so opting out reports as *skipped* (not a green pass) — important for a
    // security-adjacent test where "skipped" and "passed" must be distinguishable.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_RUN_CAPTURE_TESTS"] == "1",
                   "opt-in: set JARVIS_RUN_CAPTURE_TESTS=1 and grant Screen Recording to run the live capture test"))
    func protectedWindowIsExcludedFromScreenCaptureKit() async {
        await checkScreenCaptureKitExclusion()
    }
}

// MARK: - Helpers

/// Poll `condition` every 20 ms until it holds or `timeout` elapses; returns the final result. Lets a
/// timing test wait for a state transition instead of sleeping a fixed amount and racing the real
/// `DispatchQueue.main` timer — the test adapts to the production code rather than the reverse.
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
    // macOS 26 normalizes sharingType (won't hold a non-`.none` value we write), so we can't simulate
    // a "dropped flag". Instead assert the re-assert code actually runs: showing a response must
    // re-apply exclusion (and leave it `.none`). Guards the defense-in-depth re-assert from deletion.
    let overlay = OverlayPanel()
    let before = overlay.captureExclusionReassertCount

    overlay.render(["Stay hidden.", "Even after a reset."], perLineSeconds: 0.05)
    // Poll for the re-assert rather than sleeping a fixed amount and racing render's main-actor hop.
    #expect(await waitUntil { overlay.captureExclusionReassertCount > before }, "render() must re-assert capture exclusion")
    #expect(overlay.currentSharingType == .none)
}

// render() trims each line and drops empties; if nothing survives it must NOT show the panel. Since
// only show() bumps captureExclusionReassertCount, an unchanged count proves the empty-guard held.
@MainActor
private func checkEmptyLinesDoNotShow() async {
    let overlay = OverlayPanel()
    let before = overlay.captureExclusionReassertCount

    overlay.render([], perLineSeconds: 0.05)
    overlay.render(["   ", "", "\n\t"], perLineSeconds: 0.05)
    try? await Task.sleep(nanoseconds: 200_000_000)   // give any erroneous main-actor hop time to run

    #expect(overlay.captureExclusionReassertCount == before,
            "empty/whitespace-only lines must not show the overlay")
}

// A newer tip must not interrupt one still on screen: it queues and plays after the current tip
// finishes, so no hint is dropped. The "first is STILL up when second arrives" assertion is the
// flaky-prone one, so we give the first line a long display window (3s) and check the instant it
// appears — a ~3s margin before its timer could fire, vs. the old 0.2s. The queued tip is then
// awaited via polling rather than a fixed sleep, so neither check races the real timer.
@MainActor
private func checkTipsQueue() async {
    let overlay = OverlayPanel()
    let hold: TimeInterval = 3   // long enough that "first" can't advance before we check it

    overlay.render(["first"], perLineSeconds: hold)
    overlay.render(["second"], perLineSeconds: hold)   // arrives while "first" is up — must queue, not replace

    // Wait for the first tip to actually reach the screen (render hops to the main actor), then confirm
    // the newer tip did NOT replace it. We're still ~3s inside "first"'s window, so this can't flip.
    #expect(await waitUntil { overlay.currentText == "first" }, "the first tip should display")
    #expect(overlay.currentText == "first", "a newer tip must not interrupt one still on screen")

    // After "first"'s window (+ the inter-line gap) elapses, the queued tip must take over.
    #expect(await waitUntil(timeout: hold + 2) { overlay.currentText == "second" },
            "the queued tip must display after the first finishes")
}

// Once the queue fully drains, the panel must hide and reset so the next coaching turn can display.
@MainActor
private func checkDrainThenHide() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0   // isolate the drain→hide timing from the inter-line gap

    // Poll each transition rather than sleeping a fixed amount and racing the real DispatchQueue.main
    // timer — a fixed wait after the 0.3s window slips on a loaded CI runner and the panel reads as
    // still-visible. Same polling discipline as `checkTipsQueue` above.
    overlay.render(["only"], perLineSeconds: 0.3)
    #expect(await waitUntil { overlay.isPanelVisible }, "the tip should be on screen while displaying")
    #expect(await waitUntil { !overlay.isPanelVisible }, "the panel must hide once the queue drains")

    overlay.render(["again"], perLineSeconds: 0.3)    // a fresh tip after drain must display immediately
    #expect(await waitUntil { overlay.currentText == "again" }, "state must reset so the next tip shows")
    #expect(overlay.isPanelVisible)
}

// Between two lines of one tip the panel must briefly blank, so a glancing eye registers that the
// text changed (the borrowed captioning minimum-gap idea). Poll each forward transition
// (L1 → blank → L2) rather than sampling at fixed sleeps that race the real timer on a loaded runner.
@MainActor
private func checkInterLineGapBlanks() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0.5

    overlay.render(["L1", "L2"], perLineSeconds: 0.4)   // L1, then a 0.5s blank gap, then L2
    #expect(await waitUntil { overlay.currentText == "L1" }, "the first line should be up before the gap")
    // The gap (0.5s) is long enough that catching the blank by polling leaves ample margin to also
    // observe the panel is still on screen during it.
    #expect(await waitUntil { overlay.currentText == "" }, "the panel must blank between consecutive lines")
    #expect(overlay.isPanelVisible, "the gap must blank the TEXT while the panel stays on screen — not hide it")
    #expect(await waitUntil { overlay.currentText == "L2" }, "the next line must appear after the gap")
}

// render(_:perLineSeconds:[TimeInterval]) zips lines with their times, then trims and drops empties
// while keeping the two aligned. The convenience scalar overload always builds a same-length array, so
// this drives the array form directly: a leading empty line must be dropped AND its time dropped with
// it, so the surviving line is shown for ITS own duration (a misaligned zip/filter would use 0.1s).
@MainActor
private func checkRenderAlignsTimesWhenDroppingEmptyLines() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0

    // Wide contrast: the dropped whitespace line carries 0.1s, the survivor a long 3.0s. Wait for the
    // survivor to appear, then confirm it's STILL up a short moment later — a misaligned zip/filter
    // would have shortened it to 0.1s and it'd already be gone. The 3.0s window dwarfs both the 0.25s
    // recheck and any main-actor observation latency on a loaded runner, so the recheck can't race the
    // window's end (the failure mode when the survivor used only a 0.6s window).
    overlay.render(["   ", "survivor"], perLineSeconds: [0.1, 3.0])
    #expect(await waitUntil { overlay.currentText == "survivor" }, "the surviving line must appear")
    try? await Task.sleep(nanoseconds: 250_000_000)
    #expect(overlay.currentText == "survivor", "the surviving line must keep ITS own duration, not the dropped line's")
    #expect(overlay.isPanelVisible)
}

// Opening the Settings appearance preview mid-tip must PAUSE the tip (showing the sample), then on
// close RESUME the exact line it stopped on — and a tip that arrived while the preview was open must
// play afterwards. Guards the regression where the preview stranded the queue / dropped a tip.
@MainActor
private func checkPreviewResumesTip() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0   // isolate pause/resume timing from the inter-line gap

    // Poll each forward transition rather than sleeping fixed amounts that race the real timer:
    // A1 up → preview owns the panel → resume reaches A2 → the queued B1 plays last.
    overlay.render(["A1", "A2"], perLineSeconds: 0.6)   // line A1 shows; A2 scheduled next
    #expect(await waitUntil { overlay.currentText == "A1" }, "the first line should be up")
    overlay.showAppearancePreview(true)                 // pause the tip; sample takes the panel
    overlay.render(["B1"], perLineSeconds: 0.6)         // a new tip arrives while previewing — must wait
    #expect(await waitUntil { overlay.currentText == "Sample overlay text" }, "preview must own the panel while open")

    overlay.showAppearancePreview(false)                // close Settings: resume the paused tip
    #expect(await waitUntil { overlay.currentText == "A2" }, "the paused tip must resume its remaining line, not be dropped")
    #expect(await waitUntil { overlay.currentText == "B1" }, "a tip that arrived during preview must play after the resumed tip")
}

@MainActor
private func checkScreenCaptureKitExclusion() async {
    guard CGPreflightScreenCaptureAccess() else {
        Issue.record("JARVIS_RUN_CAPTURE_TESTS=1 is set but this process lacks Screen Recording permission — grant it to the terminal and re-run.")
        return
    }
    guard let screen = NSScreen.main else { Issue.record("no main screen"); return }

    // Rare, well-separated colors so a solid-fill scan can't be fooled by ordinary UI pixels.
    let protectedColor: (r: UInt8, g: UInt8, b: UInt8) = (123, 47, 201)   // purple
    let controlColor:   (r: UInt8, g: UInt8, b: UInt8) = (47, 201, 123)   // teal

    let f = screen.frame
    let protectedPanel = makeSolidPanel(color: protectedColor, protected: true,
                                        rect: NSRect(x: f.minX + 140, y: f.minY + 380, width: 900, height: 240))
    let controlPanel = makeSolidPanel(color: controlColor, protected: false,
                                      rect: NSRect(x: f.minX + 140, y: f.minY + 90, width: 900, height: 240))
    defer { protectedPanel.orderOut(nil); controlPanel.orderOut(nil) }

    try? await Task.sleep(nanoseconds: 700_000_000)   // let the windows render

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

        // tolerance 40 deliberately wide: the capture round-trips through the display profile
        // (sRGB fill → deviceRGB scan), so exact RGB drifts. Don't tighten it without re-checking.
        let counts = countMatchingPixels(image, targets: [protectedColor, controlColor], tolerance: 40, step: 3)
        let protectedCount = counts[0]
        let controlCount = counts[1]

        // Sanity: capture is live and the control window IS visible (rules out a blank/failed grab).
        #expect(controlCount > 500,
                "control window not found in capture (\(controlCount) px) — capture or display mapping is wrong")
        // The real assertion: the .none window must be essentially absent. A leak would produce a
        // pixel count comparable to the control (same size); exclusion produces ~0. Phrased as
        // "control dominates" (control is >20x protected, i.e. protected is <5%).
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

/// Draws the image into a known RGBA8 buffer and counts pixels (sampled every `step`) within
/// `tolerance` of each target color. Returns one count per target.
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
