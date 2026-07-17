import CoreGraphics
import Foundation
import ImageIO

/// A local 64-bit difference hash. Downsampling to 9x8 grayscale makes duplicate suppression
/// tolerant of JPEG noise and tiny pixel drift while retaining large layout/diagram changes.
enum ScreenPerceptualHash {
    static func make(fromJPEG data: Data) -> UInt64? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return make(from: image)
    }

    static func make(from image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        return pixels.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let context = CGContext(
                data: buffer.baseAddress, width: 9, height: 8,
                bitsPerComponent: 8, bytesPerRow: 9,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))

            var result: UInt64 = 0
            for row in 0..<8 {
                for column in 0..<8 {
                    result <<= 1
                    if bytes[row * 9 + column] > bytes[row * 9 + column + 1] {
                        result |= 1
                    }
                }
            }
            return result
        }
    }
}
