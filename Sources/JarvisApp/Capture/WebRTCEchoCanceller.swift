import Foundation
import JarvisCore
import CJarvisAEC

/// Acoustic echo cancellation over the WebRTC AEC3 shim (`CJarvisAEC`). The system audio ("them") is
/// registered as the far-end reference and the mic ("me") is cleaned against it, so the other side's
/// voice leaking off the speakers into the mic is removed BEFORE transcription — no headphones
/// required, and the user's own voice is untouched (we enable only AEC + a high-pass, no noise
/// suppression or AGC; see scripts/aec/jarvis_aec.cpp).
///
/// Our wire format is 24 kHz mono PCM16, but AEC3 only accepts 8/16/32/48 kHz on fixed 10 ms frames,
/// so each side resamples 24→48 kHz (`Resampler`) and re-chunks into 480-sample frames
/// (`PCM16Framer`); the cleaned mic is resampled back to 24 kHz for the transcription socket.
///
/// `@unchecked Sendable`: the far side (`registerReference`) and the near side (`cancel`) are each
/// driven by a single, distinct capture thread (the SCStream sample queue and the mic tap), and they
/// touch disjoint state (`far*` vs `near*`/`down`). The shared `aec` handle is the WebRTC APM, which
/// is designed for exactly this render-thread + capture-thread split. Do not call either method from
/// more than one thread.
final class WebRTCEchoCanceller: @unchecked Sendable {
    private let aec: OpaquePointer
    private let frameSize: Int             // 10 ms at the AEC rate (480 at 48 kHz)

    // Far ("them") side state — touched only by registerReference.
    private let farUp: Resampler
    private var farFramer: PCM16Framer

    // Near ("me") side state — touched only by cancel.
    private let nearUp: Resampler
    private let nearDown: Resampler
    private var nearFramer: PCM16Framer

    /// Build a canceller for the 24 kHz wire format running AEC3 internally at 48 kHz. Returns nil if
    /// the canceller or a resampler can't be created, so the caller can fall back to a raw mic.
    init?(wireRateHz: Double = 24_000, aecRateHz: Int32 = 48_000) {
        guard let aec = jarvis_aec_create(aecRateHz),
              let farUp = Resampler(fromHz: wireRateHz, toHz: Double(aecRateHz)),
              let nearUp = Resampler(fromHz: wireRateHz, toHz: Double(aecRateHz)),
              let nearDown = Resampler(fromHz: Double(aecRateHz), toHz: wireRateHz) else { return nil }
        self.aec = aec
        self.frameSize = Int(aecRateHz) / 100
        self.farUp = farUp
        self.nearUp = nearUp
        self.nearDown = nearDown
        self.farFramer = PCM16Framer(frameSize: frameSize)
        self.nearFramer = PCM16Framer(frameSize: frameSize)
    }

    /// Register a chunk of far-end ("them" / system) 24 kHz PCM16 as the echo reference.
    func registerReference(_ farPCM24k: Data) {
        for var frame in farFramer.push(farUp.convert(farPCM24k.int16Samples)) {
            _ = jarvis_aec_process_reverse(aec, &frame, Int32(frame.count))
        }
    }

    /// Clean a chunk of near-end ("me" / mic) 24 kHz PCM16 and return it at 24 kHz, echo removed.
    /// Output may lag input by up to one frame (the framer holds the remainder); the transcription
    /// socket buffers, so that's fine.
    func cancel(_ nearPCM24k: Data) -> Data {
        var cleaned48k: [Int16] = []
        for var frame in nearFramer.push(nearUp.convert(nearPCM24k.int16Samples)) {
            _ = jarvis_aec_process(aec, &frame, Int32(frame.count))
            cleaned48k.append(contentsOf: frame)
        }
        guard !cleaned48k.isEmpty else { return Data() }
        return Data(int16Samples: nearDown.convert(cleaned48k))
    }

    deinit { jarvis_aec_destroy(aec) }
}

extension Data {
    /// Reinterpret the bytes as little-endian Int16 samples (PCM16 is always an even byte count).
    var int16Samples: [Int16] {
        guard count >= 2 else { return [] }
        return withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    init(int16Samples samples: [Int16]) {
        self = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
