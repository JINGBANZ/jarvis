import Foundation
import JarvisCore

/// @unchecked: lock guards synthetic text and capture observations; base is Sendable.
final class ReplayScreen: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let base: any ScreenCapturing
    private var text: String?
    private var captured: [String] = []
    init(base: any ScreenCapturing) { self.base = base }
    var observations: [String] { lock.withLock { captured } }
    func update(_ value: String) { lock.withLock { text = value } }
    func makeAttemptCapture() -> any ScreenCapturing {
        ReplayAttemptScreen(owner: self, base: base.makeAttemptCapture())
    }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        capture(selection, using: base)
    }
    fileprivate func capture(_ selection: ScreenCaptureSelection, using attempt: any ScreenCapturing) -> ScreenSnapshot? {
        guard let text = lock.withLock({ text }), let snapshot = attempt.capture(selection) else { return nil }
        lock.withLock { captured.append(text) }
        return ScreenSnapshot(imageBase64: snapshot.imageBase64,
            textEvidence: [.init(text: text, source: .onDeviceOCR, coverage: .currentViewport)])
    }
    func cancelCapture() { base.cancelCapture() }
}

private struct ReplayAttemptScreen: ScreenCapturing {
    let owner: ReplayScreen
    let base: any ScreenCapturing
    func makeAttemptCapture() -> any ScreenCapturing {
        ReplayAttemptScreen(owner: owner, base: base.makeAttemptCapture())
    }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        owner.capture(selection, using: base)
    }
    func cancelCapture() { base.cancelCapture() }
}
