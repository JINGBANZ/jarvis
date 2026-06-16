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
/// Note: the bundled swift-testing toolchain miscompiles `@MainActor` + `async` `@Test`
/// ("global variable must be a compile-time constant to use @section"), and XCTest isn't available on
/// a Command-Line-Tools-only install. So the async tests are nonisolated `@Test`s that `await` a
/// `@MainActor` helper, which keeps the AppKit work on the main actor while sidestepping the bug.
@Suite struct OverlayInvisibilityTests {

    @MainActor @Test
    func overlaySetsCaptureExclusionAtInit() {
        let overlay = OverlayPanel()
        #expect(overlay.currentSharingType == .none)
    }

    @Test
    func overlayReassertsExclusionWhenShown() async {
        await checkReassertOnShow()
    }

    @Test
    func protectedWindowIsExcludedFromScreenCaptureKit() async {
        guard ProcessInfo.processInfo.environment["JARVIS_RUN_CAPTURE_TESTS"] == "1" else {
            return   // not opted in — skip silently (see the suite doc comment for how to run it)
        }
        await checkScreenCaptureKitExclusion()
    }
}

// MARK: - Main-actor checks (called via `await` from the nonisolated tests)

@MainActor
private func checkReassertOnShow() async {
    // macOS 26 normalizes sharingType (won't hold a non-`.none` value we write), so we can't simulate
    // a "dropped flag". Instead assert the re-assert code actually runs: showing a response must
    // re-apply exclusion (and leave it `.none`). Guards the defense-in-depth re-assert from deletion.
    let overlay = OverlayPanel()
    let before = overlay.captureExclusionReassertCount

    overlay.render("Stay hidden. Even after a reset.", maxSentences: 3, perSentenceSeconds: 0.05)
    try? await Task.sleep(nanoseconds: 300_000_000)   // real await → lets render's main-actor hop run

    #expect(overlay.captureExclusionReassertCount > before, "render() must re-assert capture exclusion")
    #expect(overlay.currentSharingType == .none)
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

        let counts = countMatchingPixels(image, targets: [protectedColor, controlColor], tolerance: 40, step: 3)
        let protectedCount = counts[0]
        let controlCount = counts[1]

        // Sanity: capture is live and the control window IS visible (rules out a blank/failed grab).
        #expect(controlCount > 500,
                "control window not found in capture (\(controlCount) px) — capture or display mapping is wrong")
        // The real assertion: the .none window must be essentially absent. A leak would produce a
        // pixel count comparable to the control (same size); exclusion produces ~0.
        #expect(protectedCount * 20 < controlCount,
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
