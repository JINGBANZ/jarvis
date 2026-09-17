import Foundation
import Vision
import JarvisCore
import JarvisScreenCapture

/// Language correction stays off: it "fixes" code identifiers such as `cnt` into English words.
struct ScreenTextRecognizer: ImageTextRecognizing, Sendable {
    /// Nil when recognition fails or the image holds no text.
    func recognizedText(inJPEG jpeg: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: jpeg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let fragments = (request.results ?? []).compactMap { observation -> TextFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision boxes have a bottom-left origin; `RecognizedTextLayout` expects top-left.
            let box = observation.boundingBox
            return TextFragment(string: candidate.string,
                                minX: Double(box.minX), minY: Double(1 - box.maxY),
                                width: Double(box.width), height: Double(box.height))
        }
        return RecognizedTextLayout.orderedText(fragments)
    }
}
