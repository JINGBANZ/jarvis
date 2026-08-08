import Testing
@testable import JarvisCore

@Suite struct TurnSubstanceTests {
    /// Only clear vocal hesitation sounds in the shipped languages are discarded.
    @Test func clearHesitationSoundsAreFiller() {
        for text in ["Hmm", "hm", "uh", "Um...", "er", "erm", "oh", "Ah",
                     "嗯", "啊", "哦", "噢", "呃"] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// Elongation/repetition variants normalize onto their base form — the reason the closed-class
    /// list doesn't need to enumerate "hmmm", "mmmm", "嗯嗯", …
    @Test func elongationsCollapseOntoTheList() {
        for text in ["Hmmmm.", "mmm", "uhhh", "ummmm", "ohhh", "ahhh", "嗯嗯嗯"] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// One transcription completion can contain several separated hesitation sounds.
    @Test func compositeHesitationSoundsAreFiller() {
        for text in ["Oh. Hmm.", "Uh. Hmm. Oh, oh.", "uh um hmm", "Hmm. 嗯，呃。"] {
            #expect(!TurnSubstance.isSubstantive(text), "expected filler: \(text)")
        }
    }

    /// Short replies can change the conversation. Preserve them for either speaker and let the
    /// model interpret their meaning from context.
    @Test func contextDependentTerseRepliesFailOpenForEitherSpeaker() {
        let replies = [
            "OK", "Okay", "Yes", "Yeah", "No", "Nope", "Right", "Sure", "So", "Wow",
            "Cool", "Got it", "I see", "Alright", "Mhm", "Mm-hmm", "Uh-huh",
            "好", "好的", "对", "对的", "是", "是的", "明白", "可以", "行", "了解",
            "No. Okay.", "Yes. Hmm.", "对。嗯。",
        ]
        for speaker in [Speaker.me, .them] {
            for text in replies {
                let line = TranscriptLine(speaker: speaker, text: text, at: 1)
                #expect(TurnSubstance.isSubstantive(line), "expected substance: \(text)")
            }
        }
    }

    /// Unknown short fragments fail open. A length rule would discard technical terms and terse
    /// answers merely because they are short; pure punctuation remains content-free.
    @Test func unknownShortFragmentsFailOpen() {
        for text in ["の", "え", "네", "ja", "R", "Go", "C++", "B.F.S."] {
            #expect(TurnSubstance.isSubstantive(text), "expected substance: \(text)")
        }
        for text in ["!!", "…", ""] {
            #expect(!TurnSubstance.isSubstantive(text), "expected noise: \(text)")
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
