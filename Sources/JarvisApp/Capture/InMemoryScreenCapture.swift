import AppKit
import ImageIO
import JarvisCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Full-resolution second stage of the visual monitor. ScreenActivityPoller handles cheap change /
/// idle observations; this type runs only after quiescence (plus once to seed the baseline). It never
/// creates a temporary file. A snapshot handed to CoachDriver may later become the one auditable
/// session screenshot.
struct InMemoryScreenCapture: Sendable {
    private let preferences: ScreenCapturePreferences
    private let recognizer = ScreenTextRecognizer()

    init(preferences: ScreenCapturePreferences) {
        self.preferences = preferences
    }

    func capture() async -> ScreenSnapshot? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return nil }

        let scope = preferences.scope
        let activeWindow = scope == .activeWindow
            ? WindowScopedScreenCapture.frontWindowID().flatMap { wantedID in
                content.windows.first(where: { $0.windowID == CGWindowID(wantedID) })
            }
            : nil

        let filter: SCContentFilter
        let shouldSendRecognizedText: Bool
        if let activeWindow {
            filter = SCContentFilter(desktopIndependentWindow: activeWindow)
            shouldSendRecognizedText = true
        } else {
            // Active-window fallbacks always use the main display. A previously selected secondary
            // display applies only when the user explicitly chose entire-display scope, matching
            // WindowScopedScreenCapture and ScreenCaptureCLI.
            let displayIndex = scope == .entireDisplay ? preferences.displayIndex : 1
            guard let display = await selectedDisplay(
                index: displayIndex, in: content.displays
            ) else { return nil }
            filter = SCContentFilter(display: display, excludingWindows: [])
            shouldSendRecognizedText = false
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let capturedAt = ProcessInfo.processInfo.systemUptime
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ), let jpeg = Self.jpegData(from: image) else { return nil }

        // Whole-display OCR is useful locally for duplicate suppression, but is intentionally not sent
        // to the model: it would turn unrelated display clutter into tokens. Only its content-free hash
        // survives this call. Active-window OCR still rides with the screenshot as an exact reading aid.
        let localText = recognizer.recognizedText(inJPEG: jpeg)
        return ScreenSnapshot(
            capturedAt: capturedAt,
            imageBase64: jpeg.base64EncodedString(),
            recognizedText: shouldSendRecognizedText ? localText : nil,
            changeFingerprint: localText.flatMap(
                ScreenChangeDetector.privacyPreservingTextFingerprint),
            visualFingerprint: ScreenPerceptualHash.make(from: image))
    }

    private func selectedDisplay(index selectedIndex: Int,
                                 in displays: [SCDisplay]) async -> SCDisplay? {
        let selectedID: CGDirectDisplayID? = await MainActor.run {
            let screens = NSScreen.screens
            let screen = selectedIndex <= screens.count ? screens[selectedIndex - 1] : screens.first
            return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
        }
        if let selectedID, let display = displays.first(where: { $0.displayID == selectedID }) {
            return display
        }
        return displays.first
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
