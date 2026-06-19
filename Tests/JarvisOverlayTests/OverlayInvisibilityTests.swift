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

// MARK: - Deterministic tick scheduler for ordering tests

/// Records scheduled ticks and fires them on demand, so overlay playback is driven step-by-step with
/// no wall-clock waits — removing the timing race that made the real `DispatchQueue.main` timer flaky.
@MainActor
final class ManualOverlayScheduler: OverlayTickScheduler {
    private var pending: [(id: Int, body: @MainActor () -> Void)] = []
    private var nextId = 0

    func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any OverlayTickToken {
        let id = nextId; nextId += 1
        pending.append((id, body))
        return ManualOverlayTickToken(scheduler: self, id: id)
    }

    /// Fire the oldest pending tick, simulating its timer elapsing. Returns false if none was pending.
    @discardableResult
    func fireNext() -> Bool {
        guard !pending.isEmpty else { return false }
        let next = pending.removeFirst()
        next.body()
        return true
    }

    var pendingCount: Int { pending.count }
    fileprivate func cancel(id: Int) { pending.removeAll { $0.id == id } }
}

@MainActor
private struct ManualOverlayTickToken: OverlayTickToken {
    let scheduler: ManualOverlayScheduler
    let id: Int
    func cancel() { scheduler.cancel(id: id) }
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
    try? await Task.sleep(nanoseconds: 300_000_000)   // real await → lets render's main-actor hop run

    #expect(overlay.captureExclusionReassertCount > before, "render() must re-assert capture exclusion")
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
// finishes, so no hint is dropped. Driven by a manual scheduler so the assertion that "first" is
// STILL up when "second" arrives can't race a real timer (the old wall-clock version could overshoot
// the 0.6s window before the check and flip the result). `await Task.yield()` flushes render's
// main-actor hop; ticks then advance playback deterministically.
@MainActor
private func checkTipsQueue() async {
    let scheduler = ManualOverlayScheduler()
    let overlay = OverlayPanel(scheduler: scheduler)

    overlay.render(["first"], perLineSeconds: 5)    // duration is nominal — ticks fire on demand, not by clock
    await Task.yield()                              // let render's main-actor hop run show()
    overlay.render(["second"], perLineSeconds: 5)   // arrives while "first" is up — must queue, not replace
    await Task.yield()

    #expect(overlay.currentText == "first", "a newer tip must not interrupt one still on screen")

    // Advance playback: the first line's display elapses (→ inter-line blank), then the blank elapses
    // (→ the tip finishes and the queued "second" plays).
    scheduler.fireNext()
    scheduler.fireNext()
    #expect(overlay.currentText == "second", "the queued tip must display after the first finishes")
}

// Once the queue fully drains, the panel must hide and reset so the next coaching turn can display.
@MainActor
private func checkDrainThenHide() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0   // isolate the drain→hide timing from the inter-line gap

    overlay.render(["only"], perLineSeconds: 0.3)
    try? await Task.sleep(nanoseconds: 100_000_000)   // ~0.1s: tip on screen
    #expect(overlay.isPanelVisible, "the tip should be on screen while displaying")

    try? await Task.sleep(nanoseconds: 400_000_000)   // ~0.5s: the 0.3s window elapsed → drain → hide
    #expect(!overlay.isPanelVisible, "the panel must hide once the queue drains")

    overlay.render(["again"], perLineSeconds: 0.3)    // a fresh tip after drain must display immediately
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(overlay.currentText == "again", "state must reset so the next tip shows")
    #expect(overlay.isPanelVisible)
}

// Between two lines of one tip the panel must briefly blank, so a glancing eye registers that the
// text changed (the borrowed captioning minimum-gap idea). Wide windows (0.4s line, 0.5s gap) keep
// the mid-gap and post-gap samples clear of the edges on a loaded runloop.
@MainActor
private func checkInterLineGapBlanks() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0.5

    overlay.render(["L1", "L2"], perLineSeconds: 0.4)   // L1: 0–0.4s, blank gap: 0.4–0.9s, L2: 0.9s+
    try? await Task.sleep(nanoseconds: 200_000_000)     // ~0.2s: still on L1
    #expect(overlay.currentText == "L1", "the first line should be up before the gap")

    try? await Task.sleep(nanoseconds: 400_000_000)     // ~0.6s: inside the 0.4–0.9s blank gap
    #expect(overlay.currentText == "", "the panel must blank between consecutive lines")
    #expect(overlay.isPanelVisible, "the gap must blank the TEXT while the panel stays on screen — not hide it")

    try? await Task.sleep(nanoseconds: 500_000_000)     // ~1.1s: past the gap, second line up
    #expect(overlay.currentText == "L2", "the next line must appear after the gap")
}

// render(_:perLineSeconds:[TimeInterval]) zips lines with their times, then trims and drops empties
// while keeping the two aligned. The convenience scalar overload always builds a same-length array, so
// this drives the array form directly: a leading empty line must be dropped AND its time dropped with
// it, so the surviving line is shown for ITS own duration (a misaligned zip/filter would use 0.1s).
@MainActor
private func checkRenderAlignsTimesWhenDroppingEmptyLines() async {
    let overlay = OverlayPanel()
    overlay.interLineGapSeconds = 0

    overlay.render(["   ", "survivor"], perLineSeconds: [0.1, 0.6])
    try? await Task.sleep(nanoseconds: 200_000_000)   // ~0.2s: if times misaligned, "survivor" got 0.1s and is gone
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

    overlay.render(["A1", "A2"], perLineSeconds: 0.6)   // line A1 shows; A2 scheduled at ~0.6s
    try? await Task.sleep(nanoseconds: 200_000_000)     // ~0.2s: still on A1
    overlay.showAppearancePreview(true)                 // pause the tip; sample takes the panel
    overlay.render(["B1"], perLineSeconds: 0.6)         // a new tip arrives while previewing — must wait

    try? await Task.sleep(nanoseconds: 200_000_000)     // ~0.4s
    #expect(overlay.currentText == "Sample overlay text", "preview must own the panel while open")

    overlay.showAppearancePreview(false)                // close Settings: resume the paused tip at A2
    try? await Task.sleep(nanoseconds: 300_000_000)     // ~0.3s into A2's resumed 0.6s window
    #expect(overlay.currentText == "A2", "the paused tip must resume its remaining line, not be dropped")

    try? await Task.sleep(nanoseconds: 600_000_000)     // A2 elapses (~0.7s after resume); the queued tip plays
    #expect(overlay.currentText == "B1", "a tip that arrived during preview must play after the resumed tip")
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
