#if JARVIS_LIVE_E2E
import Foundation

public enum LiveE2ECacheFixture {
    public static let skillName = "cache-coaching"

    public static var config: Config {
        var config = Config.default
        config.historyCompactionTokenThreshold = 100_000
        return config
    }

    public static var skill: Skill {
        let cases = (1...80).map { index in
            """
            Practice case \(index): merchant \(index) submits \(index * 37) receipt events each hour. \
            A receipt replay may arrive \(index + 2) minutes later. Its identity combines the merchant \
            identifier and receipt identifier. Store the first accepted identity and its outcome \
            together. An identical replay returns that outcome; a changed amount with the same \
            identity goes to review. A retry after process restart follows the same rule. \
            Retain the identity for \(index + 48) hours and confirm expiry covers that merchant's \
            replay window before deleting it. The practice case has no claim that a downstream \
            charge succeeded without its recorded outcome.
            """
        }.joined(separator: "\n\n")
        return Skill(
            name: skillName,
            description: "Coach spoken questions about the fictional Harbor Ledger receipt-replay interview. Load this reference before advising on that interview.",
            body: """
            # Harbor Ledger coaching reference

            The reference calls the durable duplicate identity a **replay key**. When the candidate \
            asks what to say about duplicate receipt handling, include the words replay key in a \
            short connected hint. Answer the current spoken question; do not request a screenshot. \
            The fictional system has no editor or visible diagram. Keep the hint practical and \
            speak once when asked for help. Skill guidance remains applicable throughout this interview.

            The preparation document describes the fictional Harbor Ledger project. When the \
            candidate asks for their preparation notes, load and search the preparation tool first. \
            Preserve the distinction between an accepted receipt and an observed downstream charge.

            # Merchant practice cases

            \(cases)
            """)
    }
}
#endif
