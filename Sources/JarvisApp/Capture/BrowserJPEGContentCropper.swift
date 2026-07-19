import CoreGraphics
import Foundation
import ImageIO
import JarvisCore
import UniformTypeIdentifiers

/// Removes supported browser-owned chrome from an already captured window JPEG. Failures preserve
/// the original bytes: a complete window is more useful than a missing screenshot.
struct BrowserJPEGContentCropper {
    func removingChrome(from jpeg: Data,
                        bundleIdentifier: String?,
                        windowWidthPoints: Double) -> Data {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let topInset = BrowserChromeCrop.topInsetPixels(
                  bundleIdentifier: bundleIdentifier,
                  imageWidth: image.width,
                  imageHeight: image.height,
                  windowWidthPoints: windowWidthPoints),
              // CGImage cropping uses top-left image coordinates; starting below `topInset`
              // removes those browser-owned rows while preserving the page down to its bottom.
              let cropped = image.cropping(to: CGRect(x: 0, y: topInset,
                                                      width: image.width,
                                                      height: image.height - topInset)),
              let encoded = encodeJPEG(cropped)
        else { return jpeg }
        return encoded
    }

    private func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
