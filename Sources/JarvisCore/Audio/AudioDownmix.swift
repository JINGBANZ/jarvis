import Foundation

public enum AudioDownmix {
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
