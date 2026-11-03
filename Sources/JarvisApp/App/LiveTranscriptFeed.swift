import Foundation
import JarvisCore
import JarvisOverlay

/// Keeps the Overlay Box's transcript column current while it is shown. It polls instead of
/// hooking the transcription or coaching path, so the column can never delay or change a coaching
/// outcome; the same tick advances the "speaking… Ns" counters.
@MainActor
final class LiveTranscriptFeed {
    private static let refreshInterval: TimeInterval = 0.25

    let liveSpeech = LiveSpeechTracker()
    private let transcript: RollingTranscript
    private let driver: CoachDriver
    private let overlay: OverlayBoxPanel
    private let clock: Clock
    private let sessionStart: TimeInterval
    private var timer: Timer?

    init(
        transcript: RollingTranscript,
        driver: CoachDriver,
        overlay: OverlayBoxPanel,
        clock: Clock,
        sessionStart: TimeInterval
    ) {
        self.transcript = transcript
        self.driver = driver
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = sessionStart
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard overlay.isTranscriptPaneVisible else { return }
        let start = max(0, transcript.count - TranscriptPaneContent.lineLimit)
        let snapshot = transcript.renderFrom(index: start)
        overlay.showTranscript(.make(
            lines: snapshot.lines,
            firstIndex: snapshot.upTo - snapshot.lines.count,
            handledCount: driver.handledTranscriptCount,
            live: liveSpeech.snapshot(),
            now: clock.now() - sessionStart))
    }
}
