import Testing
@testable import JarvisCore

@Suite struct DirectAddressTests {
    @Test func detectsNameAtStart() {
        #expect(DirectAddress.isAddressed("Jarvis, can you hear me?"))
        #expect(DirectAddress.isAddressed("Hey Jarvis, what's the complexity?"))
        #expect(DirectAddress.isAddressed("Hello Jarvis, if you can hear me please respond."))
        #expect(DirectAddress.isAddressed("ok jarvis do it"))
    }

    @Test func detectsCommonMistranscriptions() {
        // gpt-4o-transcribe mis-renders the proper noun; near-misses should still count.
        #expect(DirectAddress.isAddressed("Jervis are you there"))
        #expect(DirectAddress.isAddressed("javis can you check this"))
        #expect(DirectAddress.isAddressed("jarvus help me out"))
    }

    @Test func ignoresAmbientThinkingAloud() {
        #expect(!DirectAddress.isAddressed("I'll brute-force two-sum with a double loop"))
        #expect(!DirectAddress.isAddressed("what's the time complexity of that nested loop"))
        #expect(!DirectAddress.isAddressed(""))
    }

    /// The name must be near the START of the utterance — talking *about* Jarvis mid-sentence, or a
    /// collision like "Travis CI", must not trigger a forced reply.
    @Test func ignoresNameLateOrCollisions() {
        #expect(!DirectAddress.isAddressed("the travis ci build failed again"))
        #expect(!DirectAddress.isAddressed("so then I realized the whole approach with jarvis earlier was wrong and I should refactor"))
    }

    /// The direct-address prompt line must instruct the model to reply.
    @Test func directAddressPromptLineDemandsReply() {
        let ctx = TriggerContext(reason: .directAddress, secondsSinceLastSpeech: 0, sessionElapsedSeconds: 5)
        #expect(ctx.promptLine.lowercased().contains("directly"))
        #expect(ctx.promptLine.lowercased().contains("respond") || ctx.promptLine.lowercased().contains("reply"))
    }
}
