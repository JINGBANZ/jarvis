import Testing
@testable import JarvisCore

@Suite struct TranscriptionLanguageTests {
    @Test func geminiHintUsesGooglesDocumentedRegionQualifiedCodes() {
        #expect(TranscriptionLanguage.english.geminiHint == "en-US")
        #expect(TranscriptionLanguage.mandarinChinese.geminiHint == "cmn-Hans-CN")
    }

    @Test func multipleHintIsUnchangedForOpenAI() {
        #expect(TranscriptionLanguage.english.multipleHint == "en")
        #expect(TranscriptionLanguage.mandarinChinese.multipleHint == "zh-cn")
    }
}
