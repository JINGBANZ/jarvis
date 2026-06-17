@preconcurrency import AVFoundation
import ScreenCaptureKit
import JarvisCore

/// System-audio capture (the "them" side) via ScreenCaptureKit. Captures the audio coming OUT of
/// this Mac — remote meeting participants — and emits it as 24 kHz mono PCM16 `Data`, the same wire
/// format as `AudioInput` (the mic / "me" side), so it can feed a second Realtime transcription
/// socket tagged `.them`.
///
/// Reuses the Screen Recording permission already primed at launch (no new prompt). If that grant
/// is missing — or there's no display to attach to — SCK throws and we log + degrade gracefully:
/// the mic side keeps working, Jarvis just won't hear the other side until the grant is fixed.
/// `excludesCurrentProcessAudio = true` drops any audio Jarvis itself plays (precautionary — the
/// coach is a text overlay today, but it keeps a future TTS path from feeding back in).
/// Live behavior is validated by the human smoke run (SCK can't be unit-tested without a display).
final class SystemAudioInput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onPCM: @Sendable (Data) -> Void
    private let sampleQueue = DispatchQueue(label: "jarvis.systemaudio.samples")
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    /// Built lazily from the first sample buffer's REAL format (typically 48 kHz deinterleaved
    /// float); `AudioPCM` resamples whatever it is down to the 24 kHz PCM16 wire format.
    private var converter: AVAudioConverter?

    init(onPCM: @escaping @Sendable (Data) -> Void) {
        self.onPCM = onPCM
        super.init()
    }

    func start() {
        Task { await startCapture() }
    }

    private func startCapture() async {
        do {
            // A content filter needs a display even for audio-only capture; use the main display.
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                jlog("Jarvis system audio: no display to attach to; 'them' side off (mic still active)")
                return
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            // Capture at the native 48 kHz float rate (what every reference impl does — process taps
            // deliver 48 kHz regardless of request, and asking for an odd rate risks artifacts). The
            // AVAudioConverter below reads the buffer's REAL format and resamples to the 24 kHz wire
            // format, so we're correct whatever the OS actually hands back.
            config.sampleRate = 48_000
            config.channelCount = 1                               // let SCK mix down to mono for us
            config.excludesCurrentProcessAudio = true             // precautionary: don't capture any
                                                                  // audio Jarvis itself plays. Today
                                                                  // the coach is a text overlay (no
                                                                  // sound), but this keeps a future
                                                                  // TTS path from feeding back in.
            config.queueDepth = 8                                 // headroom so audio frames aren't dropped
            // We don't consume the video stream; make it as cheap as possible (tiny, slow frames).
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

            // stop() may race ahead of this slow async startup; only proceed if we're still wanted.
            guard claim(stream) else { return }
            try await stream.startCapture()
            jlog("Jarvis system audio: capturing 'them' side via ScreenCaptureKit")
        } catch {
            jlog("Jarvis system audio: capture unavailable (\(error)); mic ('me') side still active")
        }
    }

    /// Store the started stream unless stop() already fired. Synchronous so NSLock is usable here
    /// (lock/unlock are barred from async contexts under Swift 6 concurrency).
    private func claim(_ stream: SCStream) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        self.stream = stream
        return true
    }

    func stop() {
        lock.lock(); stopped = true; let s = stream; stream = nil; lock.unlock()
        s?.stopCapture { _ in }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        // The no-copy PCM buffer is only valid inside this closure, so convert synchronously here.
        let data: Data? = try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer)
            else { return nil }
            if converter == nil { converter = AVAudioConverter(from: format, to: AudioPCM.target) }
            guard let converter else { return nil }
            return AudioPCM.pcm16Data(from: pcm, using: converter)
        }
        if let data { onPCM(data) }
    }
}
