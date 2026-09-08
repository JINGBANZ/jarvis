import Testing
@testable import JarvisCore

@Suite struct TranscriptionLanguageTests {
    /// Gemini documents region-qualified codes distinct from OpenAI's `multipleHint` — see
    /// `TranscriptionLanguage.geminiHint`'s doc comment for why the two accessors diverge.
    @Test func geminiHintUsesGooglesDocumentedRegionQualifiedCodes() {
        #expect(TranscriptionLanguage.english.geminiHint == "en-US")
        #expect(TranscriptionLanguage.mandarinChinese.geminiHint == "cmn-Hans-CN")
    }

    /// `multipleHint` is OpenAI's contract and must stay exactly as it was — changing it would alter
    /// the primary (OpenAI) path's wire payload for no reason.
    @Test func multipleHintIsUnchangedForOpenAI() {
        #expect(TranscriptionLanguage.english.multipleHint == "en")
        #expect(TranscriptionLanguage.mandarinChinese.multipleHint == "zh-cn")
    }
}
