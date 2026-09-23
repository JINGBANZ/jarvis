import Testing
import AppKit
// @preconcurrency: CI's Xcode toolchain rejects ScreenCaptureKit's non-Sendable async results
// crossing back to the @MainActor helpers.
@preconcurrency import ScreenCaptureKit

/// Async tests are nonisolated wrappers that `await` a `@MainActor` helper: `@MainActor async
/// @Test` miscompiles on the bundled swift-testing toolchain, while synchronous `@MainActor @Test`
/// is fine.
@Suite struct OverlayInvisibilityTests {
    // A condition trait, not an early return, so opting out reports skipped rather than passed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_RUN_CAPTURE_TESTS"] == "1",
                   "opt-in: set JARVIS_RUN_CAPTURE_TESTS=1 and grant Screen Recording to run the live capture test"))
    func protectedWindowIsExcludedFromScreenCaptureKit() async {
        await checkScreenCaptureKitExclusion()
    }
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
