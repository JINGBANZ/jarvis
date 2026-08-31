import CoreML
import Foundation
import JarvisCore

/// Silero VAD (16 kHz path) over Core ML: turns streamed PCM16 into one speech probability per
/// 32 ms frame. Content-free by construction, and it never persists audio.
///
/// Streaming contract, fixed by the model and mirrored from upstream's `OnnxWrapper`: 512-sample
/// chunks, each prefixed with the trailing 64 samples of the previous window, with LSTM state
/// (2, 1, 128) threaded call to call. State and context are what make consecutive calls a *stream*
/// rather than independent guesses, so both are owned here and reset together.
///
/// Not thread-safe by design: `AggregateEchoCapture` confines one instance per speaker to its
/// delivery queue, which is also what keeps probabilities in capture order.
final class SileroVoiceActivityDetector {
    /// 32 ms at 16 kHz. The endpointer needs this to convert frame counts into durations.
    static let frameDuration: TimeInterval = Double(chunkSamples) / Double(sampleRate)
    static let sampleRate = 16_000

    private static let chunkSamples = 512
    private static let contextSamples = 64
    private static let windowSamples = chunkSamples + contextSamples
    private static let stateCount = 2 * 1 * 128

    private let model: MLModel
    private let audioInput: MLMultiArray
    private let stateInput: MLMultiArray
    /// Samples carried over when a delivered chunk does not divide evenly into 512.
    private var pending: [Float] = []
    private var context = [Float](repeating: 0, count: contextSamples)

    convenience init?() {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlmodelc") else {
            jlog("Jarvis VAD: SileroVAD.mlmodelc missing from the app resources")
            return nil
        }
        self.init(modelURL: url)
    }

    init?(modelURL url: URL) {
        let configuration = MLModelConfiguration()
        // CPU only: measured fastest to load and well under budget at ~0.1 ms per frame, and it keeps
        // per-frame latency free of ANE dispatch variance on a path that runs continuously.
        configuration.computeUnits = .cpuOnly
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
            audioInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
            stateInput = try MLMultiArray(shape: [2, 1, 128], dataType: .float32)
        } catch {
            jlog("Jarvis VAD: could not load SileroVAD.mlmodelc (\(error))")
            return nil
        }
        pending.reserveCapacity(Self.windowSamples * 2)
        resetState()
    }

    struct Frame {
        let probability: Double
        /// Where this frame starts, in 16 kHz samples relative to the first sample of the `pcm16`
        /// passed to `classify`. Negative when the frame opened in audio carried over from an
        /// earlier call, which is the common case: one delivered chunk is shorter than a frame.
        let startOffsetSamples: Int
    }

    /// Classify as many whole 32 ms frames as `pcm16` completes. Leftover samples stay buffered for
    /// the next call, so frames are emitted on the model's cadence rather than the caller's.
    func classify(_ pcm16: [Int16]) -> [Frame] {
        guard !pcm16.isEmpty else { return [] }
        let carried = pending.count
        pending.reserveCapacity(carried + pcm16.count)
        for sample in pcm16 {
            pending.append(Float(sample) / 32_768)
        }

        var frames: [Frame] = []
        var consumed = 0
        while pending.count - consumed >= Self.chunkSamples {
            let chunk = pending[consumed..<(consumed + Self.chunkSamples)]
            let offset = consumed - carried
            consumed += Self.chunkSamples
            guard let probability = predict(chunk: chunk) else { break }
            frames.append(Frame(probability: probability, startOffsetSamples: offset))
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        return frames
    }

    /// Drop stream continuity. Callers use this when the audio timeline breaks, so stale LSTM state
    /// cannot colour the probabilities for unrelated audio.
    func reset() {
        pending.removeAll(keepingCapacity: true)
        context = [Float](repeating: 0, count: Self.contextSamples)
        resetState()
    }

    private func resetState() {
        let pointer = stateInput.dataPointer.bindMemory(to: Float.self, capacity: Self.stateCount)
        pointer.update(repeating: 0, count: Self.stateCount)
    }

    private func predict(chunk: ArraySlice<Float>) -> Double? {
        let audio = audioInput.dataPointer.bindMemory(
            to: Float.self, capacity: Self.windowSamples)
        context.withUnsafeBufferPointer { source in
            audio.update(from: source.baseAddress!, count: Self.contextSamples)
        }
        chunk.withUnsafeBufferPointer { source in
            (audio + Self.contextSamples).update(
                from: source.baseAddress!, count: Self.chunkSamples)
        }
        // Next window's context is this window's tail, exactly as upstream carries it.
        context = Array(
            UnsafeBufferPointer(start: audio + Self.chunkSamples, count: Self.contextSamples))

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: audioInput),
                "state_in": MLFeatureValue(multiArray: stateInput),
            ])
            let output = try model.prediction(from: input)
            guard let probability = output.featureValue(for: "prob")?.multiArrayValue,
                  let nextState = output.featureValue(for: "state_out")?.multiArrayValue else {
                reportPredictionFailure("model returned no prob/state_out")
                return nil
            }
            let state = stateInput.dataPointer.bindMemory(
                to: Float.self, capacity: Self.stateCount)
            let produced = nextState.dataPointer.bindMemory(
                to: Float.self, capacity: Self.stateCount)
            state.update(from: produced, count: Self.stateCount)
            return probability[0].doubleValue
        } catch {
            reportPredictionFailure("\(error)")
            return nil
        }
    }

    private var reportedPredictionFailure = false

    /// One line per detector: a failing model would otherwise log per frame, 31 times a second.
    private func reportPredictionFailure(_ detail: String) {
        guard !reportedPredictionFailure else { return }
        reportedPredictionFailure = true
        jlog("Jarvis VAD: Silero prediction failed (\(detail))")
    }
}
