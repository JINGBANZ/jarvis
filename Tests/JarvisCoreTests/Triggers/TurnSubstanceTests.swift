import Testing
@testable import JarvisCore

@Suite struct TurnSubstanceTests {
    /// The closed class: plain back-channels in both shipped languages are filler.
    @Test func backChannelsAreFiller() {
        for text in ["Hmm", "hm", "Mm-hmm.", "uh", "Um...", "ok", "OK.", "Okay",
                     "yeah", "Yes.", "right", "Sure", "oh", "嗯", "啊", "哦", "好的",
                     "对", "是的", "明白", "行", "了解"] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// Multi-letter back-channels whose spelling has a doubled letter ("cool", "I see") must still
    /// match: the `fillers` set is normalized with the same collapse step as the input, so a doubled
    /// letter can't silently drop an entry out of the set. Regression for the dead-entry bug.
    @Test func doubledLetterBackChannelsAreFiller() {
        for text in ["cool", "Cool.", "cooool", "I see", "I see.", "isee", "I  see"] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// Elongation/repetition variants normalize onto their base form — the reason the closed-class
    /// list doesn't need to enumerate "hmmm", "mmmm", "嗯嗯", …
    @Test func elongationsCollapseOntoTheList() {
        for text in ["Hmmmm.", "mmm", "uhhh", "ummmm", "嗯嗯", "好的好的" == "好的好的" ? "嗯嗯嗯" : "嗯嗯",
                     "okaaay", "yeahhh"] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// Short fragments are filler in ANY language — the zero-maintenance fallback for back-channels
    /// the list has never heard of.
    @Test func shortFragmentsAreFillerInAnyLanguage() {
        for text in ["m", "の", "え", "네", "ja", "!!", "…", ""] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// Questions and addresses punch through, whoever said them — including interviewer questions
    /// that should draw a proactive tip, and even a bare "ok?" that would otherwise be filler.
    @Test func questionsAndAddressesAlwaysSubstantive() {
        for text in ["那你是怎么做的?", "ok?", "嗯？", "Jarvis", "jarvis help me", "Hey Jarvis..."] {
            #expect(TurnSubstance.isSubstantive(text), "expected substance: \(text)")
        }
    }

    /// Fail open: anything not provably filler reaches the brain — real sentences, and even unknown
    /// words that merely LOOK like filler ("melon" is not on any list).
    @Test func realSpeechFailsOpenToTheBrain() {
        for text in ["I'll brute-force two-sum with a double loop",
                     "我理解的这个题目就是像一个俄罗斯方块",
                     "树的就行是吧",
                     "melon"] {
            #expect(TurnSubstance.isSubstantive(text), "expected substance: \(text)")
        }
    }
}
