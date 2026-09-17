import CoreML
import Foundation
import JarvisCore

/// The streaming contract mirrors upstream's `OnnxWrapper`: 512-sample chunks, each prefixed with
/// the previous window's last 64 samples, with (2, 1, 128) LSTM state threaded call to call.
final class SileroVoiceActivityDetector {
    static let frameDuration: TimeInterval = Double(chunkSamples) / Double(sampleRate)
    static let sampleRate = 16_000

    private static let chunkSamples = 512
    private static let contextSamples = 64
    private static let windowSamples = chunkSamples + contextSamples
    private static let stateCount = 2 * 1 * 128

    private let model: MLModel
    private let audioInput: MLMultiArray
    private let stateInput: MLMultiArray
    private var pending: [Float] = []
    private var context = [Float](repeating: 0, count: contextSamples)

    convenience init?() {
        guard let url = Self.bundledModelURL() else {
            jlog("Jarvis VAD: SileroVAD.mlmodelc missing from the app resources")
            return nil
        }
        self.init(modelURL: url)
    }

    /// Not `Bundle.module`: its generated accessor looks in the wrong places for an installed
    /// release and calls `fatalError` when the bundle is missing.
    private static func bundledModelURL() -> URL? {
        let resourceBundle = "Jarvis_JarvisApp.bundle"
        let model = "SileroVAD.mlmodelc"
        var candidates: [URL] = []
        // Installed app: the packaging scripts copy the resource bundle into Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(resourceBundle)
                .appendingPathComponent(model))
        }
        // `swift build` and the benchmark harness: SwiftPM leaves it beside the executable.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundle)
            .appendingPathComponent(model))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    init?(modelURL url: URL) {
        let configuration = MLModelConfiguration()
        // CPU only: measured fastest to load, ~0.1 ms per frame, and free of ANE dispatch variance.
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
        resetModelContinuity()
    }

    struct Frame {
        let probability: Double
        /// In 16 kHz samples from the first sample passed to `classify`. Usually negative, because
        /// a frame often begins in audio carried over from an earlier call.
        let startOffsetSamples: Int
    }

    /// Leftover samples stay buffered for the next call.
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
            // Score a failed prediction as silence, not a dropped frame: dropping it would leave an
            // open turn that never ends, while silence closes it normally.
            frames.append(Frame(
                probability: predict(chunk: chunk) ?? 0, startOffsetSamples: offset))
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        return frames
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        resetModelContinuity()
    }

    /// Context and LSTM state must describe the same point in the audio, so reset them together.
    private func resetModelContinuity() {
        context = [Float](repeating: 0, count: Self.contextSamples)
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
                return failed("model returned no prob/state_out")
            }
            let state = stateInput.dataPointer.bindMemory(
                to: Float.self, capacity: Self.stateCount)
            let produced = nextState.dataPointer.bindMemory(
                to: Float.self, capacity: Self.stateCount)
            state.update(from: produced, count: Self.stateCount)
            return probability[0].doubleValue
        } catch {
            return failed("\(error)")
        }
    }

    /// `context` already advanced past the chunk the model never consumed, so reset to keep the
    /// window and LSTM state paired. Silero reconverges within a few frames.
    private func failed(_ detail: String) -> Double? {
        reportPredictionFailure(detail)
        resetModelContinuity()
        return nil
    }

    private var reportedPredictionFailure = false

    /// One line per detector: a failing model would otherwise log per frame, 31 times a second.
    private func reportPredictionFailure(_ detail: String) {
        guard !reportedPredictionFailure else { return }
        reportedPredictionFailure = true
        jlog("Jarvis VAD: Silero prediction failed (\(detail))")
    }
}
