// The whole adapter names macOS 26 Speech APIs (`SpeechAnalyzer`, `SpeechTranscriber`,
// `AnalyzerInput`), so it compiles only when both the compiler and active SDK expose them.
// `FoundationModels` is the macOS 26 SDK marker because `Speech` itself predates those APIs. The
// fallback in `TranscriptionSessionFactory` / `AppleSpeechModelPreparation` keeps Apple Speech
// unavailable on older SDKs and when explicitly force-building the fallback.
#if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import JarvisCore
@preconcurrency import Speech

/// On-device macOS 26+ transcription session backed by `SpeechAnalyzer`. Final results enter the
/// shared Core coaching coordinator; volatile results are deliberately disabled so provisional
/// revisions never reach Activity or model context. Transcription itself stays ungated for accuracy.
/// A transient local PCM activity tracker requests analyzer finalization. The provider reports
/// settled only after the analyzer publishes finalization and this adapter consumes result progress
/// through the same submitted-audio boundary.
///
/// `@unchecked Sendable`: `lock` guards lifecycle, callback eligibility, and analyzer ownership;
/// `audioQueue` exclusively owns conversion, buffering, stream submission, and PCM activity state.
/// Callbacks are configured before `connect()` and remain immutable for the live session.
@available(macOS 26.0, *)
final class AppleSpeechTranscriber: TranscriptionSession, @unchecked Sendable {
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onTranscriptionWorkChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)?
    var onCaptureContinuity: (@Sendable (CaptureReadinessMonitor.Signal) -> Void)?

    private struct BufferedAudio {
        let data: Data
        let sequenceNumber: UInt64
        let capturedAt: TimeInterval
    }

    private struct ActiveFinalization {
        let token: TranscriptionFinalizationState.Token
        /// Exclusive analyzer time through which module results must have been consumed.
        let resultBoundary: CMTime
    }

    /// `AVAudioConverter` requires a Sendable input block. The block and this flag are confined to
    /// one synchronous `convert` call on `audioQueue`.
    private final class ConversionFeed: @unchecked Sendable {
        var supplied = false
    }

    private let locale: Locale
    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let maximumBufferedBytes: Int
    private let finalizationResultTimeout: TimeInterval
    private let continuityReporter: RealtimeContinuityReporter
    /// `nil` for every normal coaching session. Optional chaining then skips event construction.
    private let benchmark: TranscriptionBenchmarkInstrumentation?

    private let lock = NSLock()
    private let audioQueue: DispatchQueue
    private var stopped = true
    private var generation = 0
    private var terminalFailureReported = false
    private var benchmarkFinalSequence: UInt64 = 0
    /// Session-relative time of the first buffer accepted by this analyzer. SpeechAnalyzer ranges
    /// start at zero; adding this offset keeps the two independently prepared endpoints on the
    /// shared transcript/continuity clock without injecting wall-clock jitter into every buffer.
    private var analyzerTimelineOffset: TimeInterval?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var coachingCoordinator: TranscriptionCoachingCoordinator!

    /// Audio-queue-only state. Capture delivery is already serial, and this provider-local queue
    /// keeps activity observation, conversion, and stream submission ordered while setup completes.
    private var converter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var bufferedAudio: [BufferedAudio] = []
    private var bufferedByteCount = 0
    private var activityTracker = PCM16SpeechActivityTracker()
    private var finalizationState = TranscriptionFinalizationState()
    private var analyzerReadyForFinalization = false
    private var analyzerTimeScale: CMTimeScale = 1
    private var submittedAnalyzerFrameCount: Int64 = 0
    private var activeFinalization: ActiveFinalization?
    private var latestConsumedResultsFinalizationTime: CMTime?

    init(
        locale: Locale,
        speaker: Speaker,
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        silenceTimeout: TimeInterval,
        silenceMaxInterval: TimeInterval,
        silenceIdleCutoff: TimeInterval = .infinity,
        turnDebounce: TimeInterval,
        maxBufferedAudioSeconds: TimeInterval,
        finalizationResultTimeout: TimeInterval = 8,
        benchmark: TranscriptionBenchmarkInstrumentation? = nil
    ) {
        self.locale = locale
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        self.benchmark = benchmark
        self.finalizationResultTimeout = finalizationResultTimeout
        maximumBufferedBytes = TranscriptionAudioFormat.pcm16Mono.byteCount(
            forDuration: maxBufferedAudioSeconds)
        continuityReporter = RealtimeContinuityReporter(
            speaker: speaker,
            clock: clock,
            sessionStart: sessionStart,
            boundary: .appleSpeech)
        audioQueue = DispatchQueue(
            label: "jarvis.apple-speech.\(speaker.rawValue)",
            qos: .userInitiated)
        coachingCoordinator = TranscriptionCoachingCoordinator(
            speaker: speaker,
            transcript: transcript,
            clock: clock,
            sessionStart: sessionStart,
            turnDebounce: turnDebounce,
            silenceTimeout: silenceTimeout,
            silenceMaxInterval: silenceMaxInterval,
            silenceIdleCutoff: silenceIdleCutoff,
            silenceEnabled: speaker == .me,
            onTurnEnd: { [weak self] boundary in self?.onTurnEnd?(boundary) },
            onSilence: { [weak self] quiet in self?.onSilence?(quiet) },
            onTranscriptionWorkChanged: { [weak self] hasPendingWork in
                self?.onTranscriptionWorkChanged?(hasPendingWork)
            })
        continuityReporter.onCaptureContinuity = { [weak self] signal in
            self?.onCaptureContinuity?(signal)
        }
    }

    func connect() {
        audioQueue.sync {
            _ = finalizationState.reset()
            analyzerReadyForFinalization = false
            analyzerTimeScale = 1
            submittedAnalyzerFrameCount = 0
            activeFinalization = nil
            latestConsumedResultsFinalizationTime = nil
            _ = activityTracker.reset()
        }
        lock.lock()
        stopped = false
        terminalFailureReported = false
        benchmarkFinalSequence = 0
        analyzerTimelineOffset = nil
        generation += 1
        let generation = generation
        lock.unlock()

        emitState(.connecting)
        coachingCoordinator.start()
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
        self.setupTask = nil
        self.resultsTask = nil
        self.analyzer = nil
        lock.unlock()

        coachingCoordinator.stop()
        setupTask?.cancel()
        resultsTask?.cancel()
        audioQueue.async { [weak self] in
            self?.inputContinuation?.finish()
            self?.inputContinuation = nil
            self?.converter = nil
            self?.bufferedAudio.removeAll(keepingCapacity: false)
            self?.bufferedByteCount = 0
            _ = self?.activityTracker.reset()
            _ = self?.finalizationState.reset()
            self?.analyzerReadyForFinalization = false
            self?.analyzerTimeScale = 1
            self?.submittedAnalyzerFrameCount = 0
            self?.activeFinalization = nil
            self?.latestConsumedResultsFinalizationTime = nil
        }
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        continuityReporter.stop()
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
                  let converter = AVAudioConverter(from: inputFormat, to: format),
                  format.sampleRate.isFinite,
                  format.sampleRate.rounded() > 0,
                  format.sampleRate.rounded() <= Double(Int32.max) else {
                return false
            }
            self.converter = converter
            self.inputContinuation = inputContinuation
            analyzerTimeScale = CMTimeScale(format.sampleRate.rounded())
            submittedAnalyzerFrameCount = 0
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
            analyzerReadyForFinalization = true
            let effects = finalizationState.analyzerBecameAvailable()
            applyFinalizationEffects(effects, generation: generation)
            return isLive(generation: generation)
        }
        guard configured else {
            fail(generation: generation, diagnostic: "could not build the PCM converter")
            return
        }
        guard isLive(generation: generation) else { return }

        jlog("Jarvis Apple Speech [\(speaker.rawValue)]: ready "
             + "(\(locale.identifier), \(Int(format.sampleRate)) Hz).")
        benchmark?.observer.record(.init(
            kind: .ready,
            provider: TranscriptionProvider.appleSpeech.rawValue,
            localeIdentifier: locale.identifier,
            speaker: speaker.rawValue,
            generation: generation,
            observedAt: clock.now()))
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
        let frameCount = Int64(converted.frameLength)
        let bufferStartTime = CMTime(
            value: submittedAnalyzerFrameCount,
            timescale: analyzerTimeScale)
        switch continuation.yield(AnalyzerInput(
            buffer: converted,
            bufferStartTime: bufferStartTime
        )) {
        case .enqueued:
            submittedAnalyzerFrameCount += frameCount
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
        guard isLive(generation: generation) else { return }
        let resultsFinalizationTime = result.resultsFinalizationTime
        // Run this only after any accepted text below has entered the shared transcript. Apple
        // documents that `finalize` may return before the app consumes already-published results.
        defer {
            audioQueue.async { [weak self] in
                self?.recordConsumedFinalResults(
                    through: resultsFinalizationTime,
                    generation: generation)
            }
        }
        guard result.isFinal else { return }
        let raw = String(result.text.characters)

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
        let benchmarkItemID: String?
        if benchmark == nil {
            benchmarkItemID = nil
        } else {
            benchmarkFinalSequence &+= 1
            benchmarkItemID = "apple-\(generation)-\(benchmarkFinalSequence)"
        }
        lock.unlock()
        let accepted = coachingCoordinator.recordFinalizedTranscript(
            raw,
            spokenAt: spokenAt,
            source: "Apple Speech"
        )
        guard accepted else {
            // Preserve the normal adapter behavior: unusable language reaches neither coaching nor
            // continuity. An explicit benchmark alone records the provider's unavailable terminal.
            guard let benchmarkItemID, isLive(generation: generation) else { return }
            benchmark?.observer.record(.init(
                kind: .providerFinal,
                provider: TranscriptionProvider.appleSpeech.rawValue,
                localeIdentifier: locale.identifier,
                speaker: speaker.rawValue,
                generation: generation,
                itemID: benchmarkItemID,
                text: raw,
                spokenAt: sessionStart + spokenAt,
                spokenEndAt: sessionStart + spokenEnd,
                observedAt: clock.now(),
                transcriptUnavailable: true))
            benchmark?.observer.record(.init(
                kind: .finalized,
                provider: TranscriptionProvider.appleSpeech.rawValue,
                localeIdentifier: locale.identifier,
                speaker: speaker.rawValue,
                generation: generation,
                itemID: benchmarkItemID,
                spokenAt: sessionStart + spokenAt,
                spokenEndAt: sessionStart + spokenEnd,
                observedAt: clock.now(),
                transcriptUnavailable: true))
            return
        }
        benchmark?.observer.record(.init(
            kind: .providerFinal,
            provider: TranscriptionProvider.appleSpeech.rawValue,
            localeIdentifier: locale.identifier,
            speaker: speaker.rawValue,
            generation: generation,
            itemID: benchmarkItemID,
            text: raw,
            spokenAt: sessionStart + spokenAt,
            spokenEndAt: sessionStart + spokenEnd,
            observedAt: clock.now(),
            transcriptUnavailable: false))
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
        benchmark?.observer.record(.init(
            kind: .finalized,
            provider: TranscriptionProvider.appleSpeech.rawValue,
            localeIdentifier: locale.identifier,
            speaker: speaker.rawValue,
            generation: generation,
            itemID: benchmarkItemID,
            text: raw,
            spokenAt: sessionStart + spokenAt,
            spokenEndAt: sessionStart + spokenEnd,
            observedAt: clock.now(),
            transcriptUnavailable: false))
        continuityReporter.recordServerSpeech(
            .transcriptionCompleted,
            audioTimeMilliseconds: Int(max(0, spokenEnd) * 1_000),
            sessionAudioTime: spokenEnd,
            socketGeneration: generation)
    }

    private func setSpeechActivity(_ active: Bool, generation: Int) {
        guard isLive(generation: generation) else { return }
        let effects = active
            ? finalizationState.recordSpeechStarted()
            : finalizationState.recordSpeechEnded(
                analyzerAvailable: analyzerReadyForFinalization)
        applyFinalizationEffects(effects, generation: generation)
    }

    private func applyFinalizationEffects(
        _ effects: TranscriptionFinalizationState.Effects,
        generation: Int
    ) {
        if let completed = effects.completedFinalization,
           activeFinalization?.token == completed {
            activeFinalization = nil
        }
        if let pendingWork = effects.pendingWork {
            coachingCoordinator.updateTranscriptionWork(pendingWork)
        }
        guard let token = effects.finalization else { return }
        guard submittedAnalyzerFrameCount > 0 else {
            fail(
                generation: generation,
                diagnostic: "could not finalize before analyzer audio was submitted")
            return
        }
        let resultBoundary = CMTime(
            value: submittedAnalyzerFrameCount,
            timescale: analyzerTimeScale)
        let finalSampleTime = CMTime(
            value: submittedAnalyzerFrameCount - 1,
            timescale: analyzerTimeScale)
        lock.lock()
        guard !stopped, !terminalFailureReported, self.generation == generation,
              let analyzer else {
            lock.unlock()
            return
        }
        lock.unlock()
        activeFinalization = .init(token: token, resultBoundary: resultBoundary)
        if let latestConsumedResultsFinalizationTime,
           CMTimeCompare(latestConsumedResultsFinalizationTime, resultBoundary) >= 0 {
            let consumed = finalizationState.finalResultsConsumed(
                token,
                analyzerAvailable: analyzerReadyForFinalization)
            applyFinalizationEffects(consumed, generation: generation)
        }
        scheduleFinalizationResultDeadline(token: token, generation: generation)

        Task { [weak self, analyzer] in
            do {
                try await analyzer.finalize(through: finalSampleTime)
            } catch {
                self?.fail(
                    generation: generation,
                    diagnostic: "input finalization failed: \(error)")
                return
            }
            guard let self else { return }
            self.audioQueue.async { [weak self] in
                guard let self, self.isLive(generation: generation) else { return }
                let effects = self.finalizationState.analyzerFinalizationCompleted(
                    token,
                    analyzerAvailable: self.analyzerReadyForFinalization)
                self.applyFinalizationEffects(effects, generation: generation)
            }
        }
    }

    private func recordConsumedFinalResults(
        through resultsFinalizationTime: CMTime,
        generation: Int
    ) {
        guard isLive(generation: generation),
              resultsFinalizationTime.isValid,
              resultsFinalizationTime.isNumeric else { return }
        if latestConsumedResultsFinalizationTime.map({
            CMTimeCompare(resultsFinalizationTime, $0) > 0
        }) ?? true {
            latestConsumedResultsFinalizationTime = resultsFinalizationTime
        }
        guard let activeFinalization,
              CMTimeCompare(
                resultsFinalizationTime,
                activeFinalization.resultBoundary) >= 0 else { return }
        let effects = finalizationState.finalResultsConsumed(
            activeFinalization.token,
            analyzerAvailable: analyzerReadyForFinalization)
        applyFinalizationEffects(effects, generation: generation)
    }

    /// Correctness is state-based. This deadline only converts a provider/result-stream stall into
    /// the adapter's normal terminal failure instead of leaving coaching parked forever.
    private func scheduleFinalizationResultDeadline(
        token: TranscriptionFinalizationState.Token,
        generation: Int
    ) {
        let timeout = finalizationResultTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.audioQueue.async { [weak self] in
                guard let self, self.isLive(generation: generation),
                      self.activeFinalization?.token == token else { return }
                self.fail(
                    generation: generation,
                    diagnostic: "finalized results were not consumed after \(timeout)s")
            }
        }
    }

    private func fail(generation: Int, diagnostic: String) {
        lock.lock()
        guard !stopped, self.generation == generation, !terminalFailureReported else {
            lock.unlock()
            return
        }
        terminalFailureReported = true
        lock.unlock()
        coachingCoordinator.stop()
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
#endif
