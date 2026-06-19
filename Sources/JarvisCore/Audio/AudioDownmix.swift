import Foundation

/// Pure conversion from interleaved Float32 capture samples to mono PCM16 — the one bit of the audio
/// hot path that's framework-free, so it lives in Core where a test can reach it (the Core Audio
/// buffer binding that calls it stays at the OS edge). Averages channels to mono and clamps to the
/// Int16 range.
public enum AudioDownmix {
    /// `interleaved` is `frames * channels` Float32 samples, channel-interleaved. Returns one Int16
    /// per frame (channels averaged). Samples are clamped to [-1, 1] before scaling.
    public static func monoInt16(_ interleaved: [Float], channels: Int) -> [Int16] {
        let ch = max(1, channels)
        let frames = interleaved.count / ch
        guard frames > 0 else { return [] }
        var out = [Int16](repeating: 0, count: frames)
        for i in 0 ..< frames {
            var acc: Float = 0
            for c in 0 ..< ch { acc += interleaved[i * ch + c] }
            let v = max(-1, min(1, acc / Float(ch))) * 32767
            out[i] = Int16(v)
        }
        return out
    }
}
