import Foundation
import JarvisCore
import CJarvisAEC

/// WebRTC AEC3 echo canceller, driven at the AEC-native 48 kHz on 10 ms (480-sample) frames. The
/// aggregate-device capture (`AggregateEchoCapture`) feeds the system-audio tap as the far-end
/// reference and the mic as near-end — BOTH from one synchronized IOProc, the single-clock case AEC3
/// needs. There is NO resampling here (input is already 48 kHz mono); the capture downsamples to
/// 24 kHz afterward for the transcription sockets. Called from a single IOProc thread, so the framers
/// need no locking.
final class WebRTCEchoCanceller {
    private let aec: OpaquePointer
    private let frameSamples: Int32 = 480          // 10 ms at 48 kHz
    private var farFramer = PCM16Framer(frameSize: 480)
    private var nearFramer = PCM16Framer(frameSize: 480)

    init?(rateHz: Int32 = 48_000) {
        guard let handle = jarvis_aec_create(rateHz) else { return nil }
        aec = handle
    }

    /// Register far-end ("them" / system) 48 kHz mono samples as the echo reference. Call this for the
    /// callback's tap samples BEFORE `process` for the same callback's mic samples.
    func processReverse(_ far48k: [Int16]) {
        for var frame in farFramer.push(far48k) {
            _ = jarvis_aec_process_reverse(aec, &frame, frameSamples)
        }
    }

    /// Clean near-end ("me" / mic) 48 kHz mono samples; returns the echo-removed 48 kHz mono samples
    /// (a whole number of 480-frames; the remainder is held for the next call).
    func process(_ near48k: [Int16]) -> [Int16] {
        var cleaned: [Int16] = []
        for var frame in nearFramer.push(near48k) {
            _ = jarvis_aec_process(aec, &frame, frameSamples)
            cleaned.append(contentsOf: frame)
        }
        return cleaned
    }

    deinit { jarvis_aec_destroy(aec) }
}
