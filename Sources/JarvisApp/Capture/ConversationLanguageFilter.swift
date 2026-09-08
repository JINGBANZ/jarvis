import Foundation
import NaturalLanguage
import JarvisCore

/// Apple owns language identification; no custom script heuristics or model request is needed.
/// Each call creates its own recognizer so microphone, system audio, and coaching can run concurrently.
struct ConversationLanguageFilter: Sendable {
    let policy: ConversationLanguagePolicy

    func accepts(_ text: String) -> Bool {
        func acceptsFragment(_ fragment: String) -> Bool {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(fragment)
            var probabilities: [String: Double] = [:]
            for (language, probability) in recognizer.languageHypotheses(withMaximum: 8) {
                guard language != .undetermined else { continue }
                let code = language.rawValue.split(separator: "-").first.map(String.init) ?? ""
                probabilities[code, default: 0] += probability
            }
            // Short jargon is often assigned an unrelated language with low confidence (gRPC
            // as Romanian, Kubernetes as Norwegian). Preserve ambiguous text rather than losing
            // technical content. Combine script variants so Chinese confidence is not split.
            guard let prediction = probabilities.max(by: { $0.value < $1.value }),
                  prediction.value >= 0.8 else { return true }
            return policy.allows(languageCode: prediction.key)
        }
        guard acceptsFragment(text) else { return false }
        var accepted = true
        // Check sentences as well as the whole result so an English paragraph cannot hide a
        // separate Russian sentence. Do not constrain the recognizer to the allowed languages:
        // that would force unsupported speech into an allowed classification.
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) {
            sentence, _, _, stop in
            if let sentence, !acceptsFragment(sentence) {
                accepted = false
                stop = true
            }
        }
        return accepted
    }
}
