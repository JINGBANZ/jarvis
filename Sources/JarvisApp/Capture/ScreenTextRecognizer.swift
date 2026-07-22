import Foundation
import Vision
import JarvisCore

/// On-device OCR over a captured JPEG (Apple Vision — nothing leaves the machine). `.accurate`
/// with language correction OFF: correction "fixes" code identifiers (`cnt`, `prevGroupStart`)
/// into English words, and code fidelity is the whole point. Reading order is reconstructed by
/// Core's `RecognizedTextLayout`, where the geometry is unit-tested.
struct ScreenTextRecognizer {
    /// Nil when recognition fails or the image holds no text — callers just skip the sidecar.
    func recognizedText(inJPEG jpeg: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: jpeg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let fragments = (request.results ?? []).compactMap { observation -> TextFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision boxes are normalized with a bottom-left origin; flip to the top-left origin
            // RecognizedTextLayout expects (y grows downward, matching reading order).
            let box = observation.boundingBox
            return TextFragment(string: candidate.string,
                                minX: Double(box.minX), minY: Double(1 - box.maxY),
                                width: Double(box.width), height: Double(box.height))
        }
        return RecognizedTextLayout.orderedText(fragments)
    }
}
