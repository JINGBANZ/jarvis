#if JARVIS_LIVE_E2E
import AppKit
import CoreMedia
import CoreVideo
import os
@preconcurrency import ScreenCaptureKit

@MainActor
final class CapturePrivacyStream: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Measurement: Codable, Sendable {
        var frames = 0
        var markerFrames = 0
        var maximumMarkerSamples = 0
    }

    private struct State: Sendable {
        var measurement: Measurement?
        var lastMarkerSamples: Int?
        var failure: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var stream: SCStream?

    func start(displayID: CGDirectDisplayID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // Recorder-owned filtering must not hide the test windows.
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "jarvis.capture-privacy"))
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }

    func beginPhase() { state.withLock { $0.measurement = Measurement() } }

    func endPhase() throws -> Measurement {
        try state.withLock { state in
            if let failure = state.failure {
                throw NSError(domain: "CapturePrivacyStream", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: failure])
            }
            let result = state.measurement ?? Measurement()
            state.measurement = nil
            return result
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.withLock { $0.failure = error.localizedDescription }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let samples: Int?
        if status == .complete, let image = buffer.imageBuffer {
            samples = markerSamples(in: image)
        } else if status == .idle {
            // An idle frame means the previous complete image is still current.
            samples = state.withLock { $0.lastMarkerSamples }
        } else {
            return
        }
        guard let samples else { return }
        state.withLock { state in
            state.lastMarkerSamples = samples
            guard var measurement = state.measurement else { return }
            measurement.frames += 1
            if samples > 0 { measurement.markerFrames += 1 }
            measurement.maximumMarkerSamples = max(measurement.maximumMarkerSamples, samples)
            state.measurement = measurement
        }
    }

    nonisolated private func markerSamples(in image: CVPixelBuffer) -> Int? {
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let stride = CVPixelBufferGetBytesPerRow(image)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var matches = 0
        // Three adjacent sRGB stripes identify the synthetic marker, independent of the desktop.
        for y in Swift.stride(from: 0, to: height, by: 4) {
            for x in Swift.stride(from: 0, to: width - 128, by: 4) {
                let offset = y * stride + x * 4
                if matchesColor(pixels, at: offset, red: 224, green: 23, blue: 191) {
                    for stripe in 2...64 {
                        if matchesColor(pixels, at: offset + 2 * stripe * 4, red: 29, green: 36, blue: 223) {
                            let middle = offset + stripe * 4
                            if matchesColor(pixels, at: middle, red: 47, green: 201, blue: 123) {
                                matches += 1
                                break
                            }
                        }
                    }
                }
            }
        }
        return matches
    }

    nonisolated private func matchesColor(_ pixels: UnsafePointer<UInt8>, at offset: Int,
                                         red: Int, green: Int, blue: Int) -> Bool {
        abs(Int(pixels[offset]) - blue) <= 25
            && abs(Int(pixels[offset + 1]) - green) <= 25
            && abs(Int(pixels[offset + 2]) - red) <= 25
    }
}
#endif
