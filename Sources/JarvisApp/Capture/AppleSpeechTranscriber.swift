import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import JarvisCore
@preconcurrency import Speech

/// On-device macOS 26+ transcription session backed by `SpeechAnalyzer`. Final results enter the
/// same speaker-labeled transcript and coaching callbacks as the OpenAI adapter; volatile results
/// are deliberately disabled so provisional revisions never reach Activity or model context.
/// Transcription itself stays ungated for accuracy. A transient local PCM activity tracker only
/// delays turn/silence callbacks until speech settles and never retains audio.
///
/// `@unchecked Sendable`: `lock` guards lifecycle, callback eligibility, analyzer ownership, and
/// timers; `audioQueue` exclusively owns conversion, buffering, stream submission, and PCM activity
/// state. Callbacks are configured before `connect()` and remain immutable for the live session.
@available(macOS 26.0, *)
final class AppleSpeechTranscriber: TranscriptionSession, @unchecked Sendable {
    var onTurnEnd: (@Sendable () -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onSpeechActivityChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)?

    private struct BufferedAudio {
        let data: Data
        let sequenceNumber: UInt64
        let capturedAt: TimeInterval
    }

    /// `AVAudioConverter` requires a Sendable input block. The block and this flag are confined to
    /// one synchronous `convert` call on `audioQueue`.
    private final class ConversionFeed: @unchecked Sendable {
        var supplied = false
    }

    private let locale: Locale
    private let speaker: Speaker
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let turnDebounce: TimeInterval
    private let maximumBufferedBytes: Int
    private let continuityReporter: RealtimeContinuityReporter

    private let lock = NSLock()
    private let audioQueue: DispatchQueue
    private var stopped = true
    private var generation = 0
    private var terminalFailureReported = false
    private var speechActive = false
    private var turnPending = false
    /// Session-relative time of the first buffer accepted by this analyzer. SpeechAnalyzer ranges
    /// start at zero; adding this offset keeps the two independently prepared endpoints on the
    /// shared transcript/continuity clock without injecting wall-clock jitter into every buffer.
    private var analyzerTimelineOffset: TimeInterval?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var debounceTimer: Timer?
    private var silenceTimer: Timer?
    private var silenceBackoff: SilenceBackoff
    private var silencePausedLogged = false

    /// Audio-queue-only state. Capture delivery is already serial, and this provider-local queue
    /// keeps activity observation, conversion, and stream submission ordered while setup completes.
    private var converter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var bufferedAudio: [BufferedAudio] = []
    private var bufferedByteCount = 0
    private var activityTracker = PCM16SpeechActivityTracker()

    init(
        locale: Locale,
        speaker: Speaker,
        transcript: RollingTranscript,
        clock: Clock,
        silenceTimeout: TimeInterval,
        silenceMaxInterval: TimeInterval,
        silenceIdleCutoff: TimeInterval = .infinity,
        turnDebounce: TimeInterval,
        maxBufferedAudioSeconds: TimeInterval
    ) {
        self.locale = locale
        self.speaker = speaker
        self.transcript = transcript
        self.clock = clock
        let sessionStart = clock.now()
        self.sessionStart = sessionStart
        self.turnDebounce = turnDebounce
        maximumBufferedBytes = TranscriptionAudioFormat.pcm16Mono.byteCount(
            forDuration: maxBufferedAudioSeconds)
        continuityReporter = RealtimeContinuityReporter(
            speaker: speaker,
            clock: clock,
            sessionStart: sessionStart,
            boundary: .appleSpeech)
        silenceBackoff = SilenceBackoff(
            base: silenceTimeout,
            maxInterval: silenceMaxInterval,
            idleCutoff: silenceIdleCutoff)
        audioQueue = DispatchQueue(
            label: "jarvis.apple-speech.\(speaker.rawValue)",
            qos: .userInitiated)
    }

    func connect() {
        lock.lock()
        stopped = false
        terminalFailureReported = false
        speechActive = false
        turnPending = false
        analyzerTimelineOffset = nil
        generation += 1
        let generation = generation
        lock.unlock()

        emitState(.connecting)
        resetSilenceTimer()
        continuityReporter.start()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.setUp(generation: generation)
        }
        lock.lock()
        if stopped || self.generation != generation {
            lock.unlock()
            task.cancel()
        } else {
            setupTask = task
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        generation += 1
        let setupTask = setupTask
        let resultsTask = resultsTask
        let analyzer = analyzer
        let debounceTimer = debounceTimer
        let silenceTimer = silenceTimer
        let wasSpeechActive = speechActive
        self.setupTask = nil
        self.resultsTask = nil
        self.analyzer = nil
        self.debounceTimer = nil
        self.silenceTimer = nil
        speechActive = false
        turnPending = false
        lock.unlock()

        setupTask?.cancel()
        resultsTask?.cancel()
        audioQueue.async { [weak self] in
            self?.inputContinuation?.finish()
            self?.inputContinuation = nil
            self?.converter = nil
            self?.bufferedAudio.removeAll(keepingCapacity: false)
            self?.bufferedByteCount = 0
            _ = self?.activityTracker.reset()
        }
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        DispatchQueue.main.async {
            debounceTimer?.invalidate()
            silenceTimer?.invalidate()
        }
        continuityReporter.stop()
        if wasSpeechActive { onSpeechActivityChanged?(false) }
        emitState(.stopped)
    }

    func recordCapturedAudio(
        sequenceNumber: UInt64,
        sampleCount: Int,
        capturedAt: TimeInterval
    ) {
        guard isLive else { return }
        continuityReporter.recordCapture(
            sequence: sequenceNumber,
            sampleCount: sampleCount,
            at: capturedAt - sessionStart)
    }

    func sendAudio(
        _ pcm: Data,
        sequenceNumber: UInt64,
        capturedAt: TimeInterval
    ) {
        guard isLive else { return }
        continuityReporter.recordDelivery(
            sequence: sequenceNumber,
            pcm16: pcm,
            at: clock.now() - sessionStart)
        let generation = currentGeneration
        audioQueue.async { [weak self] in
            guard let self, self.isLive(generation: generation) else { return }
            if let active = self.activityTracker.observe(pcm16: pcm, at: capturedAt) {
                self.setSpeechActivity(active, generation: generation)
            }
            guard self.inputContinuation != nil, self.converter != nil else {
                self.buffer(.init(
                    data: pcm,
                    sequenceNumber: sequenceNumber,
                    capturedAt: capturedAt))
                return
            }
            self.submit(
                pcm,
                sequenceNumber: sequenceNumber,
                capturedAt: capturedAt,
                generation: generation)
        }
    }

    private func setUp(generation: Int) async {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            fail(
                generation: generation,
                diagnostic: "no compatible audio format for \(locale.identifier)")
            return
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            fail(generation: generation, diagnostic: "prepare failed: \(error)")
            return
        }
        guard isLive(generation: generation) else {
            await analyzer.cancelAndFinishNow()
            return
        }

        let resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result, generation: generation)
                }
                if !Task.isCancelled {
                    self?.fail(
                        generation: generation,
                        diagnostic: "result stream ended unexpectedly")
                }
            } catch {
                self?.fail(
                    generation: generation,
                    diagnostic: "result stream failed: \(error)")
            }
        }
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            resultsTask.cancel()
            fail(generation: generation, diagnostic: "analysis start failed: \(error)")
            return
        }
        guard isLive(generation: generation) else {
            inputContinuation.finish()
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            return
        }

        guard installRuntime(
            analyzer: analyzer,
            resultsTask: resultsTask,
            generation: generation
        ) else {
            inputContinuation.finish()
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            return
        }

        let configured = audioQueue.sync { () -> Bool in
            guard isLive(generation: generation),
                  let inputFormat = Self.inputFormat,
                  let converter = AVAudioConverter(from: inputFormat, to: format) else {
                return false
            }
            self.converter = converter
            self.inputContinuation = inputContinuation
            let pending = bufferedAudio
            bufferedAudio.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
            for chunk in pending {
                submit(
                    chunk.data,
                    sequenceNumber: chunk.sequenceNumber,
                    capturedAt: chunk.capturedAt,
                    generation: generation)
            }
            return isLive(generation: generation)
        }
        guard configured else {
            fail(generation: generation, diagnostic: "could not build the PCM converter")
            return
        }
        guard isLive(generation: generation) else { return }

        jlog("Jarvis Apple Speech [\(speaker.rawValue)]: ready "
             + "(\(locale.identifier), \(Int(format.sampleRate)) Hz).")
        emitState(.ready)
    }

    private func buffer(_ chunk: BufferedAudio) {
        bufferedAudio.append(chunk)
        bufferedByteCount += chunk.data.count
        var evictedChunks = 0
        while bufferedByteCount > maximumBufferedBytes, !bufferedAudio.isEmpty {
            bufferedByteCount -= bufferedAudio.removeFirst().data.count
            evictedChunks += 1
        }
        if evictedChunks > 0 {
            jlog("⚠️ Apple Speech [\(speaker.rawValue)] setup buffer overflow: "
                 + "evicted \(evictedChunks) oldest chunk(s)")
        }
    }

    private func submit(
        _ pcm: Data,
        sequenceNumber: UInt64,
        capturedAt: TimeInterval,
        generation: Int
    ) {
        guard isLive(generation: generation),
              let continuation = inputContinuation,
              let converted = convert(pcm) else {
            fail(generation: generation, diagnostic: "PCM conversion failed")
            return
        }
        lock.lock()
        if analyzerTimelineOffset == nil {
            analyzerTimelineOffset = max(0, capturedAt - sessionStart)
        }
        lock.unlock()
        continuityReporter.recordSendAttempt(
            sequence: sequenceNumber,
            socketGeneration: generation)
        switch continuation.yield(AnalyzerInput(buffer: converted)) {
        case .enqueued:
            continuityReporter.recordSendSuccess(
                sequence: sequenceNumber,
                socketGeneration: generation)
        case .dropped:
            continuityReporter.recordSendFailure(
                sequence: sequenceNumber,
                socketGeneration: generation)
            fail(generation: generation, diagnostic: "analysis input stream dropped audio")
        case .terminated:
            continuityReporter.recordSendFailure(
                sequence: sequenceNumber,
                socketGeneration: generation)
            fail(generation: generation, diagnostic: "analysis input stream terminated")
        @unknown default:
            fail(generation: generation, diagnostic: "unknown analysis input result")
        }
    }

    private func convert(_ pcm: Data) -> AVAudioPCMBuffer? {
        guard let converter, let inputFormat = Self.inputFormat else { return nil }
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = input.int16ChannelData?[0] else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(sampleCount)
        pcm.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channel.update(from: source, count: sampleCount)
        }

        let ratio = converter.outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sampleCount) * ratio) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: capacity) else {
            return nil
        }
        let feed = ConversionFeed()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if feed.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            feed.supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func handle(_ result: SpeechTranscriber.Result, generation: Int) {
        guard result.isFinal else { return }
        let raw = String(result.text.characters)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }

        lock.lock()
        guard !stopped, !terminalFailureReported, self.generation == generation else {
            lock.unlock()
            return
        }
        let timelineOffset = analyzerTimelineOffset ?? 0
        let resultStart = CMTimeGetSeconds(result.range.start)
        let spokenAt = resultStart.isFinite && resultStart >= 0
            ? timelineOffset + resultStart
            : clock.now() - sessionStart
        let resultEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        let spokenEnd = resultEnd.isFinite && resultEnd >= resultStart
            ? timelineOffset + resultEnd
            : spokenAt
        transcript.append(.init(speaker: speaker, text: text, at: spokenAt))
        ActivityLog.shared.record(.heard(speaker: speaker, text: text))
        jlog("🗣 heard (\(speaker.rawValue)): \"\(text)\" (Apple Speech)")
        turnPending = true
        lock.unlock()
        continuityReporter.recordServerSpeech(
            .speechStarted,
            audioTimeMilliseconds: Int(max(0, spokenAt) * 1_000),
            sessionAudioTime: spokenAt,
            socketGeneration: generation)
        continuityReporter.recordServerSpeech(
            .speechStopped,
            audioTimeMilliseconds: Int(max(0, spokenEnd) * 1_000),
            sessionAudioTime: spokenEnd,
            socketGeneration: generation)
        continuityReporter.recordServerSpeech(
            .transcriptionCompleted,
            audioTimeMilliseconds: Int(max(0, spokenEnd) * 1_000),
            sessionAudioTime: spokenEnd,
            socketGeneration: generation)
        resetSilenceTimer()
        scheduleTurnDebounce(generation: generation)
    }

    private func setSpeechActivity(_ active: Bool, generation: Int) {
        let shouldResumeTurn: Bool
        lock.lock()
        guard !stopped, !terminalFailureReported, self.generation == generation,
              speechActive != active else {
            lock.unlock()
            return
        }
        speechActive = active
        shouldResumeTurn = !active && turnPending
        lock.unlock()
        onSpeechActivityChanged?(active)
        if shouldResumeTurn {
            scheduleTurnDebounce(generation: generation)
        }
    }

    private func scheduleTurnDebounce(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped, !self.terminalFailureReported,
                  self.generation == generation else {
                self.lock.unlock()
                return
            }
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: self.turnDebounce,
                repeats: false
            ) { [weak self] _ in
                self?.fireTurn(generation: generation)
            }
            self.lock.unlock()
        }
    }

    private func fireTurn(generation: Int) {
        lock.lock()
        guard !stopped, !terminalFailureReported,
              self.generation == generation, turnPending else {
            lock.unlock()
            return
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
        guard !speechActive else {
            lock.unlock()
            return
        }
        turnPending = false
        lock.unlock()
        onTurnEnd?()
    }

    private func resetSilenceTimer() {
        guard onSilence != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLive else { return }
            self.silenceBackoff.reset()
            self.silencePausedLogged = false
            self.armSilenceTimer()
        }
    }

    private func armSilenceTimer() {
        let interval = silenceBackoff.next()
        scheduleSilenceTimer(after: interval, quietThreshold: interval)
    }

    private func scheduleSilenceTimer(
        after delay: TimeInterval,
        quietThreshold interval: TimeInterval
    ) {
        lock.lock()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { [weak self] _ in
            self?.silenceTimerDidFire(quietThreshold: interval)
        }
        lock.unlock()
    }

    private func silenceTimerDidFire(quietThreshold interval: TimeInterval) {
        lock.lock()
        let shouldDefer = stopped || terminalFailureReported || speechActive
        lock.unlock()
        guard !shouldDefer else {
            if isLive {
                scheduleSilenceTimer(after: 1, quietThreshold: interval)
            }
            return
        }
        let quiet = transcript.silenceDuration(now: clock.now() - sessionStart)
        guard quiet >= interval else {
            silenceBackoff.reset()
            silencePausedLogged = false
            armSilenceTimer()
            return
        }
        if silenceBackoff.shouldProbe(quietSoFar: quiet) {
            silencePausedLogged = false
            onSilence?(quiet)
        } else if !silencePausedLogged {
            silencePausedLogged = true
            jlog("🤫 quiet for \(Int(quiet))s — pausing silence checks until speech resumes")
        }
        armSilenceTimer()
    }

    private func fail(generation: Int, diagnostic: String) {
        lock.lock()
        guard !stopped, self.generation == generation, !terminalFailureReported else {
            lock.unlock()
            return
        }
        terminalFailureReported = true
        lock.unlock()
        jlog("Jarvis Apple Speech [\(speaker.rawValue)]: \(diagnostic)")
        emitState(.failed)
        onTerminalFailure?(.appleSpeechUnavailable)
    }

    private func installRuntime(
        analyzer: SpeechAnalyzer,
        resultsTask: Task<Void, Never>,
        generation: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !terminalFailureReported, self.generation == generation else {
            return false
        }
        self.analyzer = analyzer
        self.resultsTask = resultsTask
        return true
    }

    private var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && !terminalFailureReported
    }

    private func isLive(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && !terminalFailureReported && self.generation == generation
    }

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func emitState(_ state: TranscriptionConnectionState) {
        onConnectionStateChange?(state)
    }

    private static var inputFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(TranscriptionAudioFormat.pcm16Mono.sampleRate),
            channels: AVAudioChannelCount(TranscriptionAudioFormat.pcm16Mono.channelCount),
            interleaved: true)
    }
}
