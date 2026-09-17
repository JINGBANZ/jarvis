import Foundation
import JarvisCore
import CJarvisAEC

/// Takes 48 kHz mono only; callers resample. Called from a single IOProc thread, so the framers
/// need no locking.
final class WebRTCEchoCanceller {
    private let aec: OpaquePointer
    private let frameSamples: Int32                 // 10 ms at the AEC rate (480 at 48 kHz)
    private var farFramer: PCM16Framer
    private var nearFramer: PCM16Framer

    init?(rateHz: Int32 = 48_000) {
        guard let handle = jarvis_aec_create(rateHz) else { return nil }
        aec = handle
        let n = Int(rateHz) / 100                   // AEC3 works on 10 ms frames; matches the C shim
        frameSamples = Int32(n)
        farFramer = PCM16Framer(frameSize: n)
        nearFramer = PCM16Framer(frameSize: n)
    }

    /// Call before `process` for the same callback's mic samples.
    func processReverse(_ far48k: [Int16]) {
        for var frame in farFramer.push(far48k) {
            _ = jarvis_aec_process_reverse(aec, &frame, frameSamples)
        }
    }

    /// Returns whole 10 ms frames only; the remainder is held for the next call.
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
