import AppKit
import CoreGraphics
import JarvisCore
import ScreenCaptureKit

/// Low-rate, low-resolution one-shot captures used only as a local change signal.
///
/// A long-lived `SCStream` makes macOS show an ongoing screen-sharing control, which violates
/// Jarvis's capture-invisible interview posture. One-shot `SCScreenshotManager` captures have no
/// persistent sharing session. Each image is immediately reduced to one grayscale byte per pixel;
/// no JPEG encoding, OCR, network request, disk write, or frame retention beyond the previous
/// grayscale sample happens here.
@MainActor
final class ScreenActivityPoller {
    private enum TargetSelection: Equatable {
        case activeWindow(CGWindowID?)
        case entireDisplay(Int)
    }

    enum Event: Sendable {
        case changed(areaRatio: Double,
                     evidence: ScreenFrameActivityClassifier.ChangeEvidence)
        case idle
        case unclassifiable
    }

    typealias EventHandler = @MainActor @Sendable (Event) -> Void

    private struct Target {
        let filter: SCContentFilter
        let width: Int
        let height: Int
    }

    private let preferences: ScreenCapturePreferences
    private let frameInterval: TimeInterval
    private let onEvent: EventHandler
    private var frameClassifier: ScreenFrameActivityClassifier
    private var pollTask: Task<Void, Never>?
    private var target: Target?
    private var currentSelection: TargetSelection?
    private var generation = 0

    init(preferences: ScreenCapturePreferences, frameInterval: TimeInterval,
         minimumChangedAreaRatio: Double,
         onEvent: @escaping EventHandler) {
        precondition(frameInterval > 0)
        self.preferences = preferences
        self.frameInterval = frameInterval
        self.onEvent = onEvent
        self.frameClassifier = ScreenFrameActivityClassifier(
            minimumChangedAreaRatio: minimumChangedAreaRatio)
    }

    func start() {
        guard pollTask == nil else { return }
        generation &+= 1
        let requestedGeneration = generation
        frameClassifier.reset()
        target = nil
        currentSelection = nil
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == requestedGeneration {
                await self.pollOnce(generation: requestedGeneration)
                // Delay after completion, so a slow capture can only lower the poll rate; it can
                // never collapse into a tight loop and increase CPU/privacy pressure.
                try? await Task.sleep(for: .seconds(self.frameInterval))
            }
        }
    }

    func stop() {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        target = nil
        currentSelection = nil
        frameClassifier.reset()
    }

    private func pollOnce(generation requestedGeneration: Int) async {
        guard requestedGeneration == generation else { return }
        let selection = desiredSelection()
        let targetChanged = currentSelection != nil && selection != currentSelection
        if target == nil || selection != currentSelection {
            guard let refreshedTarget = await makeTarget(for: selection) else {
                target = nil
                onEvent(.unclassifiable)
                return
            }
            target = refreshedTarget
            currentSelection = selection
        }
        guard let target else {
            onEvent(.unclassifiable)
            return
        }

        let configuration = configuration(for: target)
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: target.filter, configuration: configuration
        ), requestedGeneration == generation,
              let pixels = Self.grayscalePixels(from: image) else {
            // Re-resolve the target on the next poll; the active window or display may have gone.
            self.target = nil
            onEvent(.unclassifiable)
            return
        }

        if targetChanged {
            // A target switch is semantically a screen change even when two windows happen to look
            // similar at 320 px. Seed the new pixel baseline and force one normal quiescence pass so
            // the full-resolution/OCR stage reconciles with the newly watched surface.
            frameClassifier.reset()
            _ = frameClassifier.observe(pixels: pixels, dirtyAreaRatio: nil)
            onEvent(.changed(areaRatio: 1, evidence: .visualPixels))
            return
        }

        switch frameClassifier.observe(pixels: pixels, dirtyAreaRatio: nil) {
        case .changed(let areaRatio, let evidence):
            onEvent(.changed(areaRatio: areaRatio, evidence: evidence))
        case .idle:
            onEvent(.idle)
        }
    }

    private func desiredSelection() -> TargetSelection {
        if preferences.scope == .activeWindow {
            return .activeWindow(WindowScopedScreenCapture.frontWindowID().map(CGWindowID.init))
        }
        return .entireDisplay(preferences.displayIndex)
    }

    private func makeTarget(for selection: TargetSelection) async -> Target? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return nil }

        if case .activeWindow(let selectedWindowID) = selection,
           let windowID = selectedWindowID,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return Target(
                filter: filter,
                width: max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))),
                height: max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))))
        }

        // Active-window fallback is always the main display. The selected display index applies
        // only when the user explicitly chose entire-display scope.
        let displayIndex = switch selection {
        case .activeWindow: 1
        case .entireDisplay(let index): index
        }
        guard let display = selectedDisplay(index: displayIndex, in: content.displays) else {
            return nil
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return Target(filter: filter, width: display.width, height: display.height)
    }

    private func configuration(for target: Target) -> SCStreamConfiguration {
        let maxDimension = 320.0
        let scale = min(1, maxDimension / Double(max(target.width, target.height)))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((Double(target.width) * scale).rounded()))
        configuration.height = max(1, Int((Double(target.height) * scale).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        return configuration
    }

    private func selectedDisplay(index selectedIndex: Int,
                                 in displays: [SCDisplay]) -> SCDisplay? {
        let screens = NSScreen.screens
        let screen = selectedIndex <= screens.count ? screens[selectedIndex - 1] : screens.first
        let selectedID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID
        if let selectedID, let display = displays.first(where: { $0.displayID == selectedID }) {
            return display
        }
        return displays.first
    }

    private static func grayscalePixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }

    deinit {
        pollTask?.cancel()
    }
}
